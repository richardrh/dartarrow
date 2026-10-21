# Changelog

## 0.1.0

- Extract the existing pure Dart Arrow arrays, schemas, values, and owned JSON
  interface from dartaframes_polars, without changing supported behavior.
- Provide optional standard C Data and C Stream ABI declarations in arrow_c.dart.
- Move the package into its standalone `richardrh/dartarrow` repository with
  independent dependency locking, checks, documentation, and manual GitHub
  draft release validation. No workflow publishes to pub.dev.
- Report missing capabilities separately from failures in the fixture probe;
  add optional `--require-full` mode to reject missing inventory entries.
