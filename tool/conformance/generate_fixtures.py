#!/usr/bin/env python3
"""Independent PyArrow 26 physical fixtures; no Dart implementation oracle."""
import argparse
import base64
import json
from decimal import Decimal, localcontext
from pathlib import Path
import pyarrow as pa

UNITS = {'s':'seconds','ms':'milliseconds','us':'microseconds','ns':'nanoseconds'}

class ConformanceExtension(pa.ExtensionType):
    def __init__(self): super().__init__(pa.int32(), 'dartaframes.conformance')
    def __arrow_ext_serialize__(self): return b'fixture-metadata'
    @classmethod
    def __arrow_ext_deserialize__(cls, storage_type, serialized): return cls()

def field(f):
    return {'name': f.name, 'type': descriptor(f.type), 'nullable': f.nullable, 'metadata': {k.decode():v.decode() for k,v in (f.metadata or {}).items()}}

def descriptor(t):
    if isinstance(t,pa.ExtensionType): return {'kind':'extension','name':t.extension_name,'storageType':descriptor(t.storage_type),'metadata':t.__arrow_ext_serialize__().decode()}
    if pa.types.is_null(t): return {'kind':'null'}
    if pa.types.is_boolean(t): return {'kind':'boolean'}
    if pa.types.is_integer(t): return {'kind':str(t)}
    if pa.types.is_floating(t): return {'kind':f'float{t.bit_width}'}
    if pa.types.is_decimal(t):
        d={'kind':'decimal','precision':t.precision,'scale':t.scale}
        if t.bit_width != 128: d['bitWidth']=t.bit_width
        return d
    if pa.types.is_timestamp(t): return {'kind':'timestamp','unit':UNITS[t.unit], **({'timeZone':t.tz} if t.tz else {})}
    if pa.types.is_duration(t): return {'kind':'duration','unit':UNITS[t.unit]}
    if pa.types.is_time(t): return {'kind':'time','unit':UNITS[t.unit]}
    if pa.types.is_date(t): return {'kind':'date','unit':'days' if pa.types.is_date32(t) else 'milliseconds'}
    for pred,kind in [(pa.types.is_string,'utf8'),(pa.types.is_large_string,'largeUtf8'),(pa.types.is_string_view,'utf8View'),(pa.types.is_binary_view,'binaryView'),(pa.types.is_large_binary,'largeBinary')]:
        if pred(t): return {'kind':kind}
    if pa.types.is_fixed_size_binary(t): return {'kind':'fixedSizeBinary','byteWidth':t.byte_width}
    if pa.types.is_binary(t): return {'kind':'binary'}
    if pa.types.is_dictionary(t): return {'kind':'dictionary','indexType':descriptor(t.index_type),'valueType':descriptor(t.value_type),'ordered':t.ordered}
    for pred,kind in [(pa.types.is_list,'list'),(pa.types.is_large_list,'largeList'),(pa.types.is_list_view,'listView'),(pa.types.is_large_list_view,'largeListView'),(pa.types.is_fixed_size_list,'fixedSizeList')]:
        if pred(t): return {'kind':kind,'field':field(t.value_field), **({'size':t.list_size} if pa.types.is_fixed_size_list(t) else {})}
    if pa.types.is_struct(t): return {'kind':'struct','fields':[field(f) for f in t]}
    if pa.types.is_map(t): return {'kind':'map','key':field(t.key_field),'item':field(t.item_field),'keysSorted':t.keys_sorted}
    if pa.types.is_union(t): return {'kind':t.mode+'Union','fields':[field(f) for f in t],'typeCodes':list(t.type_codes)}
    if pa.types.is_run_end_encoded(t): return {'kind':'runEndEncoded','runEndType':descriptor(t.run_end_type),'valueType':descriptor(t.value_type)}
    if pa.types.is_interval(t): return {'kind':'monthDayNanoInterval'}
    raise ValueError(f'Unmapped independent descriptor: {t}')

def physical(a):
    t=a.type
    if isinstance(t,pa.ExtensionType):
        p=physical(a.storage); p['descriptor']=descriptor(t); return p
    children=[]
    if pa.types.is_struct(t) or pa.types.is_union(t): children=[physical(a.field(i)) for i in range(t.num_fields)]
    elif pa.types.is_list(t) or pa.types.is_large_list(t) or pa.types.is_fixed_size_list(t) or pa.types.is_list_view(t) or pa.types.is_large_list_view(t) or pa.types.is_map(t): children=[physical(a.values)]
    elif pa.types.is_run_end_encoded(t): children=[physical(a.run_ends),physical(a.values)]
    if pa.types.is_struct(t):
        # PyArrow field() exposes a logical slice; Arrow physical struct children
        # cover the parent's full offset+length extent instead.
        for child in children:
            child['length'] += child['offset']
            child['offset'] = 0
            child['nullCount'] = -1
    # num_buffers describes only this node; Array.buffers() otherwise flattens children.
    own=a.buffers()[:t.num_buffers]
    if getattr(t,'has_variadic_buffers',False): own=a.buffers()
    if pa.types.is_null(t): own=[]
    return {'descriptor':descriptor(t),'length':len(a),'offset':a.offset,'nullCount':a.null_count,'buffers':[None if b is None else base64.b64encode(b.to_pybytes()).decode() for b in own],'children':children,'dictionary':physical(a.dictionary) if pa.types.is_dictionary(t) else None}

def reconstruct(a, p):
    """Verify normalized payloads with the independent producer itself."""
    t=a.type
    if isinstance(t,pa.ExtensionType): return pa.ExtensionArray.from_storage(t,reconstruct(a.storage,{**p,'descriptor':descriptor(t.storage_type)}))
    buffers=[None if b is None else pa.py_buffer(base64.b64decode(b)) for b in p['buffers']]
    if pa.types.is_null(t): buffers=[None]
    kwargs={'offset':p['offset'],'null_count':p['nullCount']}
    if pa.types.is_dictionary(t):
        return pa.DictionaryArray.from_buffers(t,p['length'],buffers,reconstruct(a.dictionary,p['dictionary']),**kwargs)
    children=[]
    if pa.types.is_struct(t) or pa.types.is_union(t): children=[reconstruct(a.field(i),c) for i,c in enumerate(p['children'])]
    elif pa.types.is_run_end_encoded(t): children=[reconstruct(a.run_ends,p['children'][0]),reconstruct(a.values,p['children'][1])]
    elif p['children']: children=[reconstruct(a.values,p['children'][0])]
    return pa.Array.from_buffers(t,p['length'],buffers,children=children,**kwargs)

def expected(a):
    t=a.type
    if isinstance(t,pa.ExtensionType): return [None if v is None else {'tag':'extension','storage':v} for v in expected(a.storage)]
    out=[]
    for i,s in enumerate(a):
        if not s.is_valid: out.append(None); continue
        if pa.types.is_dictionary(t): out.append({'tag':'dictionary','value':str(a.indices[i].as_py())}); continue
        if pa.types.is_floating(t):
            n=t.bit_width//8; b=a.buffers()[1].to_pybytes(); out.append({'tag':'float','width':t.bit_width,'bits':b[(a.offset+i)*n:(a.offset+i+1)*n][::-1].hex()}); continue
        if pa.types.is_integer(t): out.append({'tag':'integer','value':str(s.as_py())}); continue
        if pa.types.is_decimal(t):
            with localcontext() as ctx:
                ctx.prec=100
                out.append({'tag':'decimal','value':str(int(s.as_py().scaleb(t.scale)))})
            continue
        if pa.types.is_temporal(t) and not pa.types.is_interval(t): out.append({'tag':'temporal','value':str(s.value)}); continue
        if pa.types.is_boolean(t): out.append({'tag':'boolean','value':s.as_py()}); continue
        if pa.types.is_string(t) or pa.types.is_large_string(t) or pa.types.is_string_view(t): out.append({'tag':'string','value':s.as_py()}); continue
        if pa.types.is_binary(t) or pa.types.is_large_binary(t) or pa.types.is_fixed_size_binary(t) or pa.types.is_binary_view(t): out.append({'tag':'binary','value':list(s.as_py())}); continue
        if pa.types.is_struct(t): out.append({'tag':'struct','fields':[{'name':f.name,'value':expected(a.field(j).slice(i,1))[0]} for j,f in enumerate(t)]}); continue
        if pa.types.is_list(t) or pa.types.is_large_list(t) or pa.types.is_fixed_size_list(t) or pa.types.is_list_view(t) or pa.types.is_large_list_view(t): out.append({'tag':'list','values':expected(s.values)}); continue
        out.append({'tag':'unsupported','value':str(s.as_py())})
    return out

def cases():
    result=[]
    def add(id,a,**meta): result.append((id,a,meta))
    add('extension',pa.ExtensionArray.from_storage(ConformanceExtension(),pa.array([1,None,-2],type=pa.int32())))
    add('struct.binary',pa.array([{'value':b'\x00\xff'},None],type=pa.struct([('value',pa.binary())])))
    add('struct.timestampUTC',pa.array([{'value':0},None],type=pa.struct([('value',pa.timestamp('us',tz='UTC'))])))
    add('null',pa.nulls(3))
    add('boolean',pa.array([True,None,False,True,None,True,False,True,False,None,True]).slice(6,5))
    for signed in [True,False]:
        for width in [8,16,32,64]:
            t=getattr(pa,('int' if signed else 'uint')+str(width))()
            lo=-(1<<(width-1)) if signed else 0; hi=(1<<(width-(1 if signed else 0)))-1
            add(str(t),pa.array([lo,None,hi,1],type=t))
    for width in [16,32,64]:
        n=width//8; bits={16:[0,0x8000,0x7c00,0xfc00,0x7e01],32:[0,0x80000000,0x7f800000,0xff800000,0x7fc00001],64:[0,0x8000000000000000,0x7ff0000000000000,0xfff0000000000000,0x7ff8000000000001]}[width]
        add(f'float{width}',pa.Array.from_buffers(getattr(pa,f'float{width}')(),len(bits),[None,pa.py_buffer(b''.join(b.to_bytes(n,'little') for b in bits))]))
    for width,precision in [(32,8),(64,17),(128,38),(256,70)]:
        with localcontext() as ctx:
            ctx.prec=100
            boundary=Decimal('9'*precision).scaleb(-2)
            add(f'decimal{width}',pa.array([Decimal('12.34'),None,Decimal('-0.01'),boundary,-boundary],type=getattr(pa,f'decimal{width}')(precision,2)),missing=width!=128)
    for t in [pa.date32(),pa.date64(),pa.time32('s'),pa.time32('ms'),pa.time64('us'),pa.time64('ns')]+[x(u) for x in [pa.timestamp,pa.duration] for u in UNITS]+[pa.timestamp('ns',tz='UTC'),pa.timestamp('us',tz='America/New_York')]:
        end=86400000 if pa.types.is_date64(t) else (86400*{'s':1,'ms':1000,'us':1000000,'ns':1000000000}[t.unit]-1 if pa.types.is_time(t) else 1)
        add(str(t),pa.array([0,None,end],type=t))
    for t,vals in [(pa.string(),['',None,'λ雪']),(pa.large_string(),['',None,'λ雪']),(pa.binary(),[b'',None,b'\x00\xff']),(pa.large_binary(),[b'',None,b'\x00\xff']),(pa.binary(2),[b'ab',None,b'\x00\xff']),(pa.string_view(),['short',None,'longer than twelve bytes']),(pa.binary_view(),[b'x',None,b'longer than twelve bytes'])]:
        add(descriptor(t)['kind'],pa.array(vals,type=t),missing=pa.types.is_fixed_size_binary(t) or pa.types.is_string_view(t) or pa.types.is_binary_view(t))
    for t in [pa.list_(pa.int32()),pa.large_list(pa.int32()),pa.list_(pa.int32(),2),pa.list_view(pa.int32()),pa.large_list_view(pa.int32())]:
        add(descriptor(t)['kind'],pa.array([[1,None],None,[3,4]],type=t),missing=pa.types.is_large_list(t) or pa.types.is_list_view(t) or pa.types.is_large_list_view(t))
    add('struct',pa.array([{'a':1,'b':'x'},None,{'a':None,'b':''}],type=pa.struct([('a',pa.int32()),('b',pa.string())])))
    add('map',pa.array([[('a',1)],None,[]],type=pa.map_(pa.string(),pa.int32())),missing=True)
    for mode in ['dense','sparse']:
        ids=pa.array([0,1,0],type=pa.int8()); children=[pa.array([1,2,3]),pa.array(['a','b','c'])]
        a=pa.UnionArray.from_dense(ids,pa.array([0,1,2],type=pa.int32()),children) if mode=='dense' else pa.UnionArray.from_sparse(ids,children)
        add(mode+'Union',a,missing=True)
    for width in [16,32,64]: add(f'runEnd{width}',pa.RunEndEncodedArray.from_arrays(pa.array([2,4],type=getattr(pa,f'int{width}')()),pa.array([1,None])),missing=True)
    add('monthDayNanoInterval',pa.array([(1,2,3),None],type=pa.month_day_nano_interval()),missing=True)
    for t in [pa.int8(),pa.int16(),pa.int32(),pa.int64()]:
        add('dictionary.'+str(t),pa.DictionaryArray.from_arrays(pa.array([0,None,1,2],type=t),pa.array(['x',None,'z'])))
    add('dictionary.nested',pa.DictionaryArray.from_arrays(pa.array([0,1,None],type=pa.int8()),pa.array([[1,None],[2]],type=pa.list_(pa.int32()))))
    for width in [8,16,32,64]:
        t=getattr(pa,f'uint{width}')()
        add('dictionary.'+str(t),pa.DictionaryArray.from_arrays(pa.array([0,None,1],type=t),pa.array(['x','y'])))
    add('list.dictionary',pa.ListArray.from_arrays(pa.array([0,2,3]),pa.DictionaryArray.from_arrays(pa.array([0,1,0],type=pa.int8()),pa.array(['a','b']))))
    scalar_sources=[(id,a) for id,a,meta in result if not meta.get('missing') and (pa.types.is_boolean(a.type) or pa.types.is_integer(a.type) or pa.types.is_floating(a.type) or pa.types.is_decimal(a.type) or pa.types.is_temporal(a.type) or pa.types.is_string(a.type) or pa.types.is_large_string(a.type) or pa.types.is_binary(a.type) or pa.types.is_large_binary(a.type))]
    recursive=pa.list_(pa.struct([('values',pa.list_(pa.binary())),('at',pa.timestamp('us',tz='UTC'))]))
    add('recursive.listStructList',pa.array([[{'values':[b'\x00\xff',None],'at':0},None],None,[],[{'values':None,'at':None}]],type=recursive))
    add('recursive.listStructList.allNull',pa.array([None,None],type=recursive))
    # Boundary variants on supported layouts; all producer bytes remain independent.
    for id,a,meta in list(result):
        if not meta.get('missing') and not pa.types.is_dictionary(a.type) and not pa.types.is_null(a.type):
            add(id+'.empty',a.slice(0,0),**meta)
            if len(a)>1: add(id+'.slice',a.slice(1,len(a)-1),**meta)
    add('int32.allNull',pa.array([None,None,None],type=pa.int32()))
    # Preserve source child buffers/IEEE bits through Arrow take, never as_py().
    for id,a in scalar_sources:
        index=next(i for i,s in enumerate(a) if s.is_valid)
        last=next(i for i in range(len(a)-1,-1,-1) if a[i].is_valid)
        child=a.take(pa.array([index,None,last,index,None,last],type=pa.int32()))
        mask=pa.array([False,True,False])
        add('nested.list.'+id,pa.ListArray.from_arrays(pa.array([0,2,4,6],type=pa.int32()),child,mask=mask))
        add('nested.fixedSizeList.'+id,pa.FixedSizeListArray.from_arrays(child,2,mask=mask))
        struct_child=a.take(pa.array([last,None,index],type=pa.int32()))
        add('nested.struct.'+id,pa.StructArray.from_arrays([struct_child],names=['value'],mask=pa.array([False,False,True])))
    add('decimal128.negativeScale',pa.array([Decimal('1200'),None],type=pa.decimal128(8,-2)))
    return result

def main():
    p=argparse.ArgumentParser(); p.add_argument('--output',default=str(Path(__file__).resolve().parents[2] / 'test/conformance/fixtures/pyarrow.json')); args=p.parse_args()
    for id,a,_ in cases():
        rebuilt=reconstruct(a,physical(a))
        assert descriptor(rebuilt.type)==descriptor(a.type), id
        assert expected(rebuilt)==expected(a), f'{id}: normalized fixture changes logical values'
    payload={'version':1,'producer':{'name':'pyarrow','version':pa.__version__},'cases':[{'id':id,'family':descriptor(a.type)['kind'],'descriptor':descriptor(a.type),'array':physical(a),'expected':expected(a),**({'expectedDecoded':expected(a.dictionary_decode())} if pa.types.is_dictionary(a.type) else {}),**meta} for id,a,meta in cases()]}
    schema=pa.schema([pa.field('',pa.int32(),nullable=False,metadata={b'field':b'value'}),pa.field('',pa.string())],metadata={b'source':b'pyarrow-26'})
    payload['schemas']=[{'id':'schema.metadata.names.nullability','schema':{'fields':[field(f) for f in schema],'metadata':{k.decode():v.decode() for k,v in schema.metadata.items()}}}]
    # Legacy interval constructors were removed from PyArrow; these bytes are
    # normative format literals, not claimed to originate from PyArrow.
    for id,kind,counts in [('interval.yearMonth','yearMonthInterval',[12,0,-1]),('interval.dayTime','dayTimeInterval',[1,2,0,0,-1,3])]:
        d={'kind':kind}
        data=b''.join(n.to_bytes(4,'little',signed=True) for n in counts)
        payload['cases'].append({'id':id,'family':'interval','descriptor':d,'missing':True,'producer':{'name':'Arrow format literal','version':'1.5'},'source':'https://github.com/apache/arrow/blob/apache-arrow-26.0.0/format/Schema.fbs','array':{'descriptor':d,'length':3,'offset':0,'nullCount':1,'buffers':[base64.b64encode(bytes([5])).decode(),base64.b64encode(data).decode()],'children':[],'dictionary':None},'expected':[{'tag':'interval','components':counts[:len(counts)//3]},None,{'tag':'interval','components':counts[-len(counts)//3:]}]})
    target=Path(args.output); target.parent.mkdir(parents=True,exist_ok=True); target.write_text(json.dumps(payload,indent=2)+'\n')
if __name__=='__main__': main()
