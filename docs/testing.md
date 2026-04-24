# Testing

## How to run

```sh
./test.sh
```

`test.sh` picks `luajit` (preferred) or `lua5.1` from `$PATH`. Both run
the same Lua 5.1 semantics that Lightroom embeds.

Install on macOS:
```sh
brew install luajit
```

Install on Debian/Ubuntu:
```sh
sudo apt install luajit       # or: sudo apt install lua5.1
```

## Layout

```
tests/
  run.lua                 # entry point; discovers *_spec.lua
  mocks/_bootstrap.lua    # installs LR-SDK stubs into _G
  <Module>_spec.lua       # per-module specs
```

## Harness

- `describe('name', fn)` groups related tests.
- `it('name', fn)` runs a test; failures do not abort the file.
- Assertions: `assertEq`, `assertTrue`, `assertNil`, `assertDeepEq`.
- LR SDK mocks are registered under `_G.__lr_imports[name]` and resolved
  by the patched `import()` global. Each spec can call `resetLrMocks()`
  and then re-register per-spec mocks.

## Conventions

- Pure modules (`PathMapper`, `MappingStore`, `CatalogIndex`, `SyncEngine`,
  `ImmichAPI`, `util.Paths`) are tested directly.
- LR-coupled modules (menu scripts, `PluginInfoProvider`, `Init`) are
  **not** tested headlessly. The rule: if a module cannot be unit tested
  at all, keep it thin and delegate real work to tested pure modules.
- Tests must be deterministic. If you need timestamps, inject them.

## Adding a new spec

1. Create `tests/<Module>_spec.lua`.
2. Start with `local Module = require 'Module'`.
3. Register any LR mocks you need **before** requiring the module under
   test (module-level code runs once and may capture mocks).
4. Run `./test.sh`; confirm green.

## CI

GitHub Actions runs `./test.sh` and `./build.sh` on every push. The
workflow file is `.github/workflows/ci.yml`.
