#!/usr/bin/env python3
"""Public API differential cases produced only by pinned PyArrow 26.

Input tags describe host-language adaptations, not Arrow physical buffers.
Expected outputs are evaluated with PyArrow, never copied from Dart.
"""
import argparse
import math
import datetime
import json
import struct
from decimal import Decimal
from pathlib import Path

import pyarrow as pa
from generate_fixtures import descriptor


def dtype(spec):
    if isinstance(spec, str):
        return {'bool': pa.bool_, 'null': pa.null, 'list': pa.list_}.get(spec, getattr(pa, spec, None))()
    name, *args = spec
    if name == 'list':
        child=args[0]
        child=pa.field(child['name'],dtype(child['type']),nullable=child.get('nullable',True)) if isinstance(child,dict) else dtype(child)
        return pa.list_(child, list_size=args[1] if len(args)>1 else -1)
    if name == 'struct':
        return pa.struct([pa.field(f[0],dtype(f[1]),nullable=f[2] if len(f)>2 else True) for f in args[0]])
    if name == 'dictionary':
        return pa.dictionary(dtype(args[0]), dtype(args[1]))
    return getattr(pa, name)(*args)


def native(value):
    if isinstance(value, list):
        return [native(v) for v in value]
    if not isinstance(value, dict):
        return value
    if '$scalar' in value:
        return evaluate(value['$scalar'])
    if '$bytes' in value:
        return bytes(value['$bytes'])
    if '$int' in value:
        return int(value['$int'])
    if '$temporal' in value:
        return int(value['$temporal']['counter'])
    if '$decimal' in value:
        return Decimal(value['$decimal'])
    if '$datetime' in value:
        return datetime.datetime.fromisoformat(value['$datetime'])
    if '$float' in value:
        return struct.unpack('>d', bytes.fromhex(value['$float']))[0]
    return {k: native(v) for k, v in value.items()}


def normalized(value):
    if value is None or isinstance(value, (str, bool)):
        return value
    if isinstance(value, int):
        return {'integer': str(value)}
    if isinstance(value, float):
        return {'float64': 'nan' if math.isnan(value) else struct.pack('>d', value).hex()}
    if isinstance(value, bytes):
        return {'bytes': list(value)}
    if isinstance(value, Decimal):
        return {'decimal': str(value)}
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time, datetime.timedelta)):
        return {'temporal': str(value)}
    if isinstance(value, list):
        return [normalized(v) for v in value]
    if isinstance(value, dict):
        return {k: normalized(v) for k, v in value.items()}
    raise TypeError(type(value))


def metadata(value):
    return None if value is None else [[list(k), list(v)] for k, v in sorted(value.items())]


def field_output(f):
    return {'name': f.name, 'type': descriptor(f.type), 'nullable': f.nullable, 'metadata': metadata(f.metadata)}


def logical(s):
    if not s.is_valid:
        return None
    if pa.types.is_timestamp(s.type) or pa.types.is_duration(s.type) or pa.types.is_time(s.type) or pa.types.is_date(s.type):
        return {'temporal': {'counter': str(s.value), 'type': descriptor(s.type)}}
    if pa.types.is_decimal(s.type):
        return {'decimal': {'unscaled': str(int(s.as_py().scaleb(s.type.scale))), 'scale': s.type.scale}}
    return normalized(s.as_py())


def output(value):
    if isinstance(value, pa.Scalar):
        result = {'kind': 'Scalar', 'type': descriptor(value.type), 'isValid': value.is_valid, 'value': logical(value)}
        if pa.types.is_floating(value.type) and value.is_valid:
            a = pa.array([value], type=value.type)
            result['rawBits'] = a.buffers()[1].to_pybytes()[::-1].hex()
        if isinstance(value, pa.DictionaryScalar):
            result.update(index=output(value.index), dictionaryValue=output(value.value))
        return result
    if isinstance(value, (pa.Array, pa.ChunkedArray)):
        result = {'kind': 'Array' if isinstance(value, pa.Array) else 'ChunkedArray', 'type': descriptor(value.type), 'length': len(value), 'nullCount': value.null_count, 'values': [logical(value[i]) for i in range(len(value))], 'scalars': [output(value[i]) for i in range(len(value))]}
        if isinstance(value, pa.ChunkedArray):
            result['chunks'] = [output(c) for c in value.chunks]
        return result
    if isinstance(value, pa.Field):
        return field_output(value)
    if isinstance(value, pa.Schema):
        return {'fields': [field_output(f) for f in value], 'metadata': metadata(value.metadata)}
    if isinstance(value, (pa.Table, pa.RecordBatch)):
        return {'kind': 'Table' if isinstance(value, pa.Table) else 'RecordBatch', 'numRows': value.num_rows, 'numColumns': value.num_columns, 'schema': output(value.schema), 'columns': [output(c) for c in value.columns], 'rows': normalized(value.to_pylist())}
    if isinstance(value, list):
        return [output(v) for v in value]
    return normalized(value)


def evaluate(e):
    op = e['op']
    if op in ('array', 'scalar'):
        kw = {k: e[k] for k in ('mask', 'size', 'safe') if k in e}
        if 'type' in e:
            kw['type'] = dtype(e['type'])
        value = evaluate(e['source']) if 'source' in e else native(e['values'] if op == 'array' else e['value'])
        return getattr(pa, op)(iter(value) if e.get('iterator') else value, **kw)
    if op == 'rawHalf':
        return pa.Array.from_buffers(pa.float16(), 2, [pa.py_buffer(bytes([1])), pa.py_buffer(bytes.fromhex('017e0000'))])
    if op == 'dictionary':
        return pa.DictionaryArray.from_arrays(evaluate(e['indices']), evaluate(e['dictionary']))
    if op == 'chunked':
        return pa.chunked_array([evaluate(c) for c in e['chunks']], type=dtype(e['type']) if 'type' in e else None)
    if op == 'maskedStruct':
        return pa.StructArray.from_arrays([evaluate(c) for c in e['children']], names=e['names'], mask=pa.array(e['mask'],type=pa.bool_()))
    if op == 'field':
        return pa.field(e['name'], dtype(e['type']), nullable=e.get('nullable', True), metadata={bytes(k): bytes(v) for k,v in e['metadata']} if 'metadata' in e else None)
    if op == 'schema':
        return pa.schema([evaluate(f) for f in e['fields']], metadata={bytes(k): bytes(v) for k,v in e['metadata']} if 'metadata' in e else None)
    if op in ('batch', 'table'):
        data = {k: evaluate(v) for k,v in e['data'].items()} if isinstance(e['data'], dict) else [evaluate(v) for v in e['data']]
        kw = {k: e[k] for k in ('names',) if k in e}
        if 'schema' in e:
            kw['schema'] = evaluate(e['schema'])
        if 'metadata' in e:
            kw['metadata'] = {bytes(k): bytes(v) for k,v in e['metadata']}
        return (pa.record_batch if op == 'batch' else pa.table)(data, **kw)
    value = evaluate(e['source'])
    if op == 'fromStructBatch': return pa.RecordBatch.from_struct_array(value)
    if op == 'index': return value[e['index']]
    if op == 'slice': return value.slice(e.get('offset', 0), e.get('length'))
    if op == 'cast': return value.cast(dtype(e['type']), safe=e.get('safe', True))
    if op == 'combine': return value.combine_chunks()
    if op == 'batches': return value.to_batches(max_chunksize=e.get('maxChunkSize'))
    if op == 'column': return value.column(e['index'])
    if op == 'fieldIndex': return value.get_field_index(e['name'])
    if op == 'allFieldIndices': return value.get_all_field_indices(e['name'])
    if op == 'lookup': return value.field(e['name'])
    if op == 'equals': return value.equals(evaluate(e['other']), check_metadata=e.get('checkMetadata', False))
    if op == 'select': return value.select(e['columns'])
    if op == 'arrayEquals': return value.equals(evaluate(e['other']))
    if op == 'isValid': return value.is_valid()
    if op == 'isNull': return value.is_null(nan_is_null=e.get('nanIsNull',False))
    if op == 'scalarValue': return value.value
    if op == 'validateFull':
        value.validate(full=True)
        return value
    if op == 'scalarCompare':
        other = evaluate(e['other'])
        equal = value.equals(other)
        return {'equals':equal, 'operatorEquals':value == other,
                'equalHash':hash(value) == hash(other) if equal else None}
    raise ValueError(op)


def error_category(error):
    # Python class names are evidence, not an exact-message compatibility gate.
    if isinstance(error, IndexError): return 'range'
    if isinstance(error, (TypeError, pa.ArrowTypeError)): return 'type'
    if isinstance(error, (pa.ArrowInvalid, OverflowError)): return 'conversion'
    if isinstance(error, (ValueError, KeyError)): return 'argument'
    raise error


def cases():
    result = []
    def add(id, expression): result.append((id, expression))
    def arr(values, type=None, **kw): return {'op':'array', 'values':values, **({'type':type} if type is not None else {}), **kw}
    def unary(op, source, **kw): return {'op':op, 'source':source, **kw}
    for name, values in [('empty',[]),('null',[None,None]),('integer',[1,None,-2]),('mixed',[1,2.5,None]),('string',['a',None,'é']),('binary',[{'$bytes':[0,255]},None]),('boolean',[True,None,False]),('nested',[[1,None],None,[]]),('struct',[{'b':2},{'a':1},None]),('boolInteger',[True,1])]: add('infer.'+name,arr(values))
    for t in ['int32','string',['list','int16']]:
        for name,v in [('empty',[]),('null',[None,None])]: add('typed.'+str(t)+'.'+name,arr(v,t))
    add('mask.invalidSkipped',arr(['bad',2],'int32',mask=[True,False]))
    add('mask.trueIsNull',arr([1,2,3],mask=[False,True,False]))
    add('mask.length',arr([1,2],mask=[True]))
    add('size.listHint',arr([1,2,3],size=1))
    add('size.iteratorTruncates',arr([1,2,3],size=1,iterator=True))
    add('mask.inferenceSkipsInvalid',arr(['bad',2],mask=[True,False]))
    for t,v in [('int8',128),('uint8',-1),('int64',{'$int':'9223372036854775808'}),('uint64',{'$int':'18446744073709551615'}),('float64',{'$int':'9007199254740993'}),('float32',16777217)]:
        for safe in [True,False]: add('construct.'+t+'.'+str(safe),arr([v],t,safe=safe))
    add('scalar.typedNull',{'op':'scalar','value':None,'type':'int32'})
    add('scalar.nan',{'op':'scalar','value':{'$float':'7ff8000000000000'},'type':'float64'})
    add('float.bits',arr([{'$float':b} for b in ['8000000000000000','7ff0000000000000','fff0000000000000','7ff8000000000000']],'float64'))
    a=arr([1,None,3],'int32')
    for i in [-4,-3,-1,0,1,3]: add('index.'+str(i),unary('index',a,index=i))
    for off,length in [(0,None),(1,99),(9,None),(-1,None),(0,-1),(3,2)]: add('slice.'+str(off)+'.'+str(length),unary('slice',a,offset=off,**({'length':length} if length is not None else {})))
    for values,t in [([128],'int8'),([1.5],'int32'),([{'$int':'9007199254740993'}],'float64')]:
        for safe in [True,False]: add('cast.'+t+'.'+str(safe),unary('cast',arr(values),type=t,safe=safe))
    dictionary={'op':'dictionary','indices':arr([0,None,1,0],'int8'),'dictionary':arr(['red','blue'])}
    add('dictionary.decode',dictionary)
    for i in [0,1,2]: add('dictionary.scalar.'+str(i),unary('index',dictionary,index=i))
    chunk={'op':'chunked','chunks':[arr([],'int32'),arr([1,None],'int32'),arr([],'int32'),arr([3],'int32')]}
    add('chunk.emptyUntyped',{'op':'chunked','chunks':[]})
    add('chunk.emptyTyped',{'op':'chunked','chunks':[],'type':'int32'})
    add('chunk.withEmpty',chunk)
    add('chunk.combine',unary('combine',chunk))
    add('chunk.mismatch',{'op':'chunked','chunks':[arr([1],'int32'),arr([2],'int64')]})
    add('chunk.index',unary('index',chunk,index=-1))
    add('chunk.slice',unary('slice',chunk,offset=1,length=2))
    second={'op':'dictionary','indices':arr([0,1],'int8'),'dictionary':arr(['blue','green'])}
    add('chunk.dictionaryCombine',unary('combine',{'op':'chunked','chunks':[dictionary,second]}))
    f={'op':'field','name':'','type':'int32','nullable':False,'metadata':[[[255,0],[0,254]]]}
    sch={'op':'schema','fields':[f,{'op':'field','name':'','type':'string'}],'metadata':[[[0,255],[254]]]}
    add('field.binaryMetadata',f); add('schema.duplicates',sch)
    for op in ['fieldIndex','allFieldIndices','lookup']: add('schema.'+op,unary(op,sch,name=''))
    for op in ['batch','table']:
        obj={'op':op,'data':{'x':a,'y':arr(['a','b','c'])}}
        add(op+'.map',obj); add(op+'.column',unary('column',obj,index='x'))
        add(op+'.mismatchLength',{'op':op,'data':{'x':a,'y':arr([1])}})
        add(op+'.namesOnMap',dict(obj,names=['a','b']))
        add(op+'.schemaNames',{'op':op,'data':[a], 'schema':{'op':'schema','fields':[{'op':'field','name':'renamed','type':'int32'}],'metadata':[[[107],[118]]]}})
        add(op+'.metadataSchemaConflict',{'op':op,'data':[a], 'schema':{'op':'schema','fields':[{'op':'field','name':'x','type':'int32'}]}, 'metadata':[[[107],[118]]]})
        add(op+'.schemaTypeMismatch',{'op':op,'data':[arr(['bad'])],'schema':{'op':'schema','fields':[{'op':'field','name':'x','type':'int32'}]}})
        add(op+'.namesSchemaConflict',{'op':op,'data':[a],'names':['x'],'schema':{'op':'schema','fields':[{'op':'field','name':'x','type':'int32'}]}})
        add(op+'.schemaMapSelect',{'op':op,'data':{'x':a,'ignored':arr([True,False,True])},'schema':{'op':'schema','fields':[{'op':'field','name':'x','type':'int32'}]}})
        add(op+'.factoryMetadata',dict(obj,metadata=[[[107],[118]]]))
        add(op+'.zeroColumnHeight',unary('select',obj,columns=[]))
        add(op+'.empty',{'op':op,'data':{}})
    unaligned={'op':'table','data':{'x':chunk,'y':{'op':'chunked','chunks':[arr(['a']),arr(['b','c'])]}}}
    add('table.unaligned',unaligned)
    for size in [None,1,2,0]: add('table.batches.'+str(size),unary('batches',unaligned,**({'maxChunkSize':size} if size is not None else {})))
    aligned={'op':'table','data':{'x':{'op':'chunked','chunks':[arr([1],'int32'),arr([2,3],'int32')]},'y':{'op':'chunked','chunks':[arr(['a']),arr(['b','c'])]}}}
    add('table.alignedBatches',unary('batches',aligned))
    add('table.zeroColumnBatches',unary('batches',unary('select',aligned,columns=[]),maxChunkSize=2))
    for unit in ['s','ms','us','ns']: add('timestamp.'+unit,arr([{'$datetime':'2024-01-02T03:04:05'},None],['timestamp',unit]))
    add('timestamp.nanosecondExact',arr([{'$temporal':{'counter':'1704164645000000001','unit':'ns'}}],['timestamp','ns']))
    add('decimal.exact',arr([{'$decimal':'12345678901234567890.12'},None],['decimal128',24,2]))
    base = {'op':'schema','fields':[{'op':'field','name':'x','type':'int32'}]}
    for label,md in [('empty',[]),('present',[[[107],[118]]])]:
        other = dict(base,metadata=md)
        add('schema.metadata.'+label,other)
        for checked in [False,True]:
            add('schema.equals.'+label+'.'+str(checked),unary('equals',base,other=other,checkMetadata=checked))
            add('field.equals.'+label+'.'+str(checked),unary('equals',base['fields'][0],other=dict(base['fields'][0],metadata=md),checkMetadata=checked))
    for op in ['batch','table']:
        add(op+'.nullableFalseNull',{'op':op,'data':[arr([None],'int32')],'schema':{'op':'schema','fields':[{'op':'field','name':'x','type':'int32','nullable':False}]}})
    add('factory.existingArray',{'op':'array','source':arr([1,None],'int16')})
    add('factory.existingChunked',{'op':'array','source':{'op':'chunked','chunks':[arr([1],'int16'),arr([2],'int16')]}})
    for kind,source in [('Array',arr([1,None,3],'int16')),('Chunked',{'op':'chunked','chunks':[arr([1,None],'int16'),arr([3],'int16')]})]:
        for label,options in [('size',{'size':1}),('mask',{'mask':[True,False,False]}),('cast',{'type':'int32'}),('maskSize',{'mask':[False,False,False],'size':1})]:
            add('factory.existing'+kind+'.'+label,{'op':'array','source':source,**options})
    scalars=[{'$scalar':{'op':'scalar','value':v,'type':'int16'}} for v in [1,None]]
    add('factory.typedScalars',arr(scalars))
    add('factory.existingScalar',{'op':'scalar','source':{'op':'scalar','value':3,'type':'int16'}})
    for label,value in [('valid',3),('null',None)]:
        add('factory.existingScalar.explicitType.'+label,{'op':'scalar','source':{'op':'scalar','value':value,'type':'int16'},'type':'int32'})
    half={'op':'rawHalf'}
    add('factory.halfScalars',arr([{'$scalar':unary('index',half,index=i)} for i in [0,1]],'float16'))
    add('factory.halfScalar',{'op':'scalar','source':unary('index',half,index=0)})
    def scalar(value,type=None): return {'op':'scalar','value':value,**({'type':type} if type else {})}
    for label,left,right in [
        ('typedNull',scalar(None,'int32'),scalar(None,'int32')),
        ('nullDifferentType',scalar(None,'int32'),scalar(None,'int64')),
        ('nan',scalar({'$float':'7ff8000000000000'}),scalar({'$float':'7ff8000000000000'})),
        ('signedZero',scalar({'$float':'8000000000000000'}),scalar(0.0)),
        ('nested',scalar([1,None]),scalar([1,None])),
        ('typeParameters',scalar([1],['list','int32']),scalar([1],['list','int64'])),
        ('dictionaryRemapped',unary('index',dictionary,index=0),unary('index',{'op':'dictionary','indices':arr([1],'int8'),'dictionary':arr(['blue','red'])},index=0)),
    ]:
        add('scalar.equals.'+label,unary('scalarCompare',left,other=right))
    for label,source,t in [('null',scalar(None,'int32'),'int64'),('overflow',scalar(128),'int8'),('fraction',scalar(1.5),'int32')]:
        for safe in [True,False]:
            add('scalar.cast.'+label+'.'+str(safe),unary('cast',source,type=t,safe=safe))
    for label,values,sourceType,targetType in [
        ('list',[[1000],[1]],['list','int64'],['list','int8']),
        ('fixedList',[[1000],[1]],['list','int64',1],['list','int8',1]),
        ('struct',[{'x':1000},{'x':1}],['struct',[['x','int64']]],['struct',[['x','int8']]]),
    ]:
        add('cast.slicedHiddenPrefix.'+label,unary('cast',unary('slice',arr(values,sourceType),offset=1),type=targetType))
    left={'op':'dictionary','indices':arr([0,1],'int8'),'dictionary':arr(['red','blue'])}
    right={'op':'dictionary','indices':arr([1,0],'int8'),'dictionary':arr(['blue','red'])}
    add('array.equals.dictionaryRemapped',unary('arrayEquals',left,other=right))
    add('chunk.equals.dictionaryRemapped',unary('arrayEquals',{'op':'chunked','chunks':[left]},other={'op':'chunked','chunks':[right]}))
    for label,indices in [('nullOnly',[None]),('empty',[])]:
        left={'op':'dictionary','indices':arr(indices,'int8'),'dictionary':arr(['red'])}
        right={'op':'dictionary','indices':arr(indices,'int8'),'dictionary':arr(['blue'])}
        add('array.equals.dictionary.'+label,unary('arrayEquals',left,other=right))
    add('array.equals.nan',unary('arrayEquals',arr([{'$float':'7ff8000000000000'}]),other=arr([{'$float':'7ff8000000000000'}])))
    add('array.equals.signedZero',unary('arrayEquals',arr([{'$float':'8000000000000000'}]),other=arr([0.0])))
    add('nested.nonnullable.structNull',unary('validateFull',arr([{'x':None}],['struct',[['x','int32',False]]])))
    add('nested.nonnullable.listNull',unary('validateFull',arr([[None]],['list',{'name':'item','type':'int32','nullable':False}])))
    floats=arr([{'$float':'7ff8000000000000'},None,1.0])
    dictnull={'op':'dictionary','indices':arr([0,1,None],'int8'),'dictionary':arr(['x',None])}
    for label,source in [('array',floats),('dictionary',dictnull),('chunked',{'op':'chunked','chunks':[floats,arr([],'float64')]})]:
        add('validity.'+label+'.isValid',unary('isValid',source))
        add('validity.'+label+'.isNull',unary('isNull',source))
    add('validity.array.nanIsNull',unary('isNull',floats,nanIsNull=True))
    add('validity.chunked.nanIsNull',unary('isNull',{'op':'chunked','chunks':[floats,arr([],'float64')]},nanIsNull=True))
    for label,t in [('date32','date32'),('date64','date64'),('time32',['time32','s']),('time64',['time64','us']),('timestamp',['timestamp','ns']),('duration',['duration','ns'])]:
        add('scalar.value.'+label,unary('scalarValue',scalar(1,t)))
    add('scalar.value.typedNull',unary('scalarValue',scalar(None,['timestamp','ns'])))
    def parent(children,names,mask): return {'op':'maskedStruct','children':children,'names':names,'mask':mask}
    add('batch.structParent.maskedChild',unary('fromStructBatch',parent([arr([99,1],'int32')],['x'],[True,False])))
    add('batch.structParent.childNullIntersection',unary('fromStructBatch',parent([arr([99,None,2],'int32')],['x'],[True,False,False])))
    offsetChild=unary('slice',arr([7,99,1,2],'int32'),offset=1)
    add('batch.structParent.slicedOffsets',unary('fromStructBatch',unary('slice',parent([offsetChild],['x'],[False,True,False]),offset=1)))
    nestedDictionary={'op':'dictionary','indices':arr([0,1],'int8'),'dictionary':arr(['bad','good'])}
    add('batch.structParent.nestedDictionary',unary('fromStructBatch',parent([arr([[99],[1]]),nestedDictionary],['nested','encoded'],[True,False])))
    add('batch.structParent.zeroColumns',unary('fromStructBatch',parent([],[],[True,False,False])))
    return result


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output', default=str(Path(__file__).resolve().parents[2] / 'test/conformance/fixtures/api_pyarrow.json'))
    args=parser.parse_args()
    if pa.__version__ != '26.0.0': raise RuntimeError('Expected PyArrow 26.0.0')
    records=[]
    for id,expression in cases():
        try: expected={'ok':output(evaluate(expression))}
        except Exception as error: expected={'error':error_category(error)}
        records.append({'id':id,'input':expression,'expected':expected})
    payload={'version':1,'producer':{'name':'pyarrow','version':pa.__version__},'cases':records}
    Path(args.output).write_text(json.dumps(payload,indent=2,ensure_ascii=True)+'\n')


if __name__ == '__main__': main()
