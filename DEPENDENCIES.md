# Vendored dependencies

All listed sources are unmodified upstream files, included directly rather than
as submodules. `DEPENDENCIES.sha256` pins each included file's bytes. Only the
OpenZeppelin subset needed by this token and the forge-std source tree/licenses
are included. No package manager or runtime download is used.

| Dependency | Version | Local path | License |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) | `v5.1.0` | `lib/openzeppelin-contracts/` | MIT, included as `LICENSE` |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.6) | `v1.9.6` | `lib/forge-std/` | MIT / Apache-2.0, both included |

OpenZeppelin source archive:
`https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.1.0`

Archive SHA-256: `8a3b08cfc756437ba3343901565b18182adb42ec1e621960240a19da5d738686`

forge-std source archive:
`https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.6`

Archive SHA-256: `53d2b498183cb7dc62cf726cc6c1a222ad728b0d87976a877ca1f3ed3707b1c6`

Included OpenZeppelin contracts: `ERC20.sol`, `IERC20.sol`,
`IERC20Metadata.sol`, `Context.sol`, and `draft-IERC6093.sol`. forge-std is used
only in tests and does not become part of the deployed token. The test library
declares a broad Foundry cheatcode interface, but this project's tests never use
its environment, network, FFI, or filesystem facilities.
