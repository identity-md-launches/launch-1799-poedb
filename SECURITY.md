# Local security review

Scope: `src/POEDBToken.sol` and its vendored OpenZeppelin v5.1.0 ERC-20 dependency.
The supplied security and L2 references informed this review; no chain queries,
keys, signed transactions, or live deployments are needed for this token.

| Concern | Design and validation |
| --- | --- |
| Incorrect mint recipient | Constructor uses its direct `msg.sender`; direct and CREATE2 factory deployment tests distinguish factory, caller, and transaction origin. |
| Inflation / unexpected burns | One constructor mint of `10^27` units, no external mint or burn methods, no zero-address transfers. Supply conservation is checked after arbitrary operation sequences. |
| Privileged theft or freezing | No ownership or administrative extensions. Deployer and stranger calls to common admin selectors fail; deployer spending still requires holder approval. |
| Incorrect allowance accounting | Standard finite/infinite allowance rules. Tests cover revoke, replacement, exhaustion, separate spenders, and rollback after failure. |
| Arithmetic errors | Amounts use integer smallest units. OpenZeppelin checks balances and allowances before subtraction. Boundary and fuzz tests include zero, full supply, and uint256 limits. |
| Transfer fees / broken launch flows | Standard untaxed transfers, with distribution and pool-facing transfer tests. No special launch exemption configuration is needed. |
| Reentrancy / callbacks | Token has no outgoing external calls. A receiver that rejects every callback still receives tokens. |
| Upgrades / dangerous opcodes | No proxies, external libraries, delegate calls, callcode, or selfdestruct in the token design. |
| L2 execution assumptions | No block-number, time, sequencer, oracle, precompile, or cross-chain dependencies. Compiler targets Paris EVM instructions. |

The local checks are Foundry compilation, unit tests, fuzz tests using the
assignment seed, stateful invariant tests, and formatting checks. Vendored files
can be checked against `DEPENDENCIES.sha256`. Slither and Mythril were not run.

Recorded result with Solidity 0.8.26: **33 tests passed, 0 failed**. The five fuzz
tests each completed 512 cases; the invariant suite completed 8,192 actions
without a handler revert. Compilation and formatting checks passed, and every
vendored file matched its recorded checksum. Inspection of the compiled artifact
confirmed a 1,814-byte runtime, no library link references, no constructor
arguments, and only the intended ERC-20 functions plus `INITIAL_SUPPLY`. An
instruction-aware scan, skipping PUSH data as the protected check does, found no
DELEGATECALL, CALLCODE, or SELFDESTRUCT opcodes.

This is a developer self-review, not an independent security audit. The separate
launch review must validate the protected factory/Uniswap integration checks and
deployed bytes before release. No claim is made about the security or operation
of PoEDB's website, the launch infrastructure, or the target chain.

Operational limits are documented in the README: immutable behavior, ordinary
ERC-20 approval risks, no asset recovery, and no administrative emergency switch.
