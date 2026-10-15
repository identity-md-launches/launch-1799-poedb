# poedb (POEDB)

A fixed-supply ERC-20 token. The sole production contract is
[`POEDBToken`](src/POEDBToken.sol), built on the vendored OpenZeppelin Contracts
v5.1.0 ERC-20 implementation.

## Behavior and assumptions

| Parameter | Value |
| --- | --- |
| Solidity identifier | `POEDBToken` |
| Name | `poedb` |
| Symbol | `POEDB` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`) |
| Constructor value | `0` native currency |
| Initial recipient | Direct constructor caller, `msg.sender` |

The constructor calls `_mint` exactly once for `INITIAL_SUPPLY`. In a factory
deployment, the factory receives the entire supply; neither the caller of the
factory nor the transaction origin receives tokens from the constructor. There
are no external calls during construction and no initialization transaction.

The supplied [PoEDB website](https://poedb.tw/us/) is a Path of Exile information
database. It supplies project context. The brief specifies a token, with no
on-chain website integration, game-item redemption, rewards, oracle, governance,
or affiliation verification. None of those additional behaviors is assumed.

Transfers and approved `transferFrom` calls move the exact requested amount.
There are no transfer taxes, rebases, caps on transfers, trading activation
switches, allowlists, or special addresses. Zero-value transfers between nonzero
addresses are permitted and emit `Transfer`; self-transfers preserve balances.
Transfers to the zero address revert. Successful ERC-20 mutations return `true`;
invalid operations revert with OpenZeppelin's ERC-6093 custom errors.

Approvals replace the current allowance. A finite allowance decreases when
spent; `type(uint256).max` is an unlimited allowance and does not decrease.
`approve` emits `Approval`; this OpenZeppelin version does not emit an additional
`Approval` when `transferFrom` spends an allowance. Indexers should read
`allowance(owner, spender)` for current values. A failed transfer rolls back
allowance changes as well as balances.

## Authority and security boundaries

There is no owner, minter, pause authority, blacklist, seizure function, public
burn function, proxy, or upgrade mechanism. The deployer has no special powers
after construction. Holders move their own balances; approved spenders may move
only the allowed amount. The internal mint/burn machinery inherited from
OpenZeppelin is not externally callable. Total supply remains fixed forever.

The token makes no external calls during transfers, so receiver callbacks and
reentrancy are absent. It has no oracle, signatures, randomness, block-number
logic, timestamps, bridge, or chain-specific addresses. The EVM target is
explicitly `paris`, sufficient for this ERC-20 and avoiding a dependency on later
opcodes. The launch chain and factory infrastructure remain deployment concerns.

Recipients must be able to control or use received tokens: ERC-20 transfers do
not check for a receiver interface. Tokens sent to the token contract itself or
an inaccessible address cannot be recovered by an administrator. Direct native
currency payments revert, and there is no asset recovery function. Holders are
responsible for choosing recipients and spenders. To change a nonzero allowance,
clients can revoke it to zero and confirm that transaction before granting a new
amount, reducing the usual ERC-20 allowance replacement race.

## Build and checks

Foundry and Solidity **0.8.26** are required. `foundry.toml` pins that compiler,
optimizer settings, and `bytecode_hash = "none"`. All Solidity dependencies and
their licenses are ordinary files under `lib/`; no install, submodule, network
access, RPC, account, environment file, FFI, or filesystem cheatcodes are needed
to build or test. The compiler must already be installed in an offline verifier.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xa565198e4aada17a31cb9307a0fe834b8d1a9e33f0c1a080661813768c1b5822 forge test
forge fmt --check
sha256sum --check DEPENDENCIES.sha256
```

The seed is supplied to Foundry by the command; tests never read or mutate the
environment. Each test has independent local state. Fuzz tests run 512 cases
each. The invariant test runs 128 sequences of 64 actions across four holders,
checking balances, allowances, rejected spending, and supply conservation against
an accounting model.

The suite also checks metadata, one mint event, direct and CREATE2 factory
deployments, full-supply and zero transfers, event contents, contract recipients,
approval replacement/revocation, finite and unlimited allowances, unauthorized
spending, insufficient funds, zero addresses, revert atomicity, and rejected
administrative selectors. `LaunchTransfers.t.sol` checks the exact ERC-20 amounts
through distribution, claims, and pool-facing transfers. It does not simulate a
Uniswap AMM or prove swap pricing. The supplied protected harness is responsible
for actual pool initialization and swaps in the later launch review.

See [SECURITY.md](SECURITY.md) for the local review and its limits, and
[DEPENDENCIES.md](DEPENDENCIES.md) for vendored source provenance.

## Deployment parameters and responsibilities

Deploy artifact `src/POEDBToken.sol:POEDBToken` with no constructor arguments and
no value. Its Solidity name is 10 characters and it has no library link
placeholders. `out/POEDBToken.sol/POEDBToken.json` contains the build artifact;
`forge inspect src/POEDBToken.sol:POEDBToken abi` displays the interface.

For the assigned launch, the deployment service uses Robinhood Chain (chain id
`4663`) and the launch factory. The token deliberately does not hardcode this
chain or any infrastructure address. The factory receives all `10^27` units
before it performs the launch distribution. Test fixture addresses are only
local test actors and are never production parameters.

The launch configuration supplied with the assignment is recorded here for the
separate manifest/deployment step; these values are not token constructor
arguments or token features:

| Launch field | Supplied value / responsibility |
| --- | --- |
| Paired currency | Native ETH, represented by the protocol's zero-address sentinel |
| Pool fee | `12500` (1.25%; an AMM fee, not a token transfer tax) |
| Tick spacing | `60` |
| Pool initialPrice field | `79228162514264337593543950336` |
| Actual opening price | Derived by the launch deployer from market cap, supply, and token ordering |
| Swarm | Factory sends 10% to its launch MerkleDistributor |
| `economics.poolBps` | `8800` (88% of the total supply) |
| `economics.initialMarketCapWei` | `10000000000000000000` (10 ETH) |
| `economics.remainderTo` | `0xa0074758e8586e940db6b91ad623b9c44194dc09` |
| Remainder | 2% of the total supply, forwarded by the factory |
| Application contracts | None |

The token constructor performs no allocation or pool setup itself. The launch
service supplies its factory/distributor/pool infrastructure, writes
`launch.json` in the separate manifest step, carries out the distribution and
liquidity operations, signs deployment transactions, verifies deployed bytecode
and source, and records the deployed address. This project contains no launch
manifest, broadcast script, or credentials.

## After launch

No token setters, owner actions, keepers, initialization calls, or recurring
maintenance are required. The launch operator should verify the token metadata,
the `10^27` total supply, the constructor mint to the factory, the factory's
distribution events, and the intended pool deployment. Publish the verified
contract address and matching compiler settings. Wallets and integrations use
18 decimals and the standard ERC-20 interface. Review and operation of the
factory, distributor, pool, and chain infrastructure remain with their respective
operators; this token cannot administer them.
