OronBox build patches on upstream commit 23e36bd.

The Dart executor API, generated bindings and Rust executor sources are unchanged.
The upstream package version is preserved; use a fixed Git tag for distribution.

The build hook compiles the bundled Rust source for the requested target rather
than copying a host library. Per-target working directories isolate wasmi/wasmtime
selection. Android builds target API 24 and 16 KiB ELF alignment. The hook checks
binary format, architecture and load-segment alignment before bundling it.

Dynamic loading always produces a cdylib: linking_enabled must not be interpreted
as a request for static .a output. Both backend Cargo lockfiles are versioned.
The initial Rust compilation requires rustup and an installed platform toolchain.
