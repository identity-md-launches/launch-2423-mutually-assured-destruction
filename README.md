# Mutually Assured Destruction (MAD)

A plain, fixed-supply ERC-20 token for an IdentityMD custom-token launch on Ethereum (chain id 1).

| Field | Value |
| --- | --- |
| Solidity contract | `MADToken` (`src/MADToken.sol`) |
| `name()` | `Mutually Assured Destruction` |
| `symbol()` | `MAD` |
| `decimals()` | `18` |
| Total supply | `1,000,000,000 MAD` = `1000000000000000000000000000` minor units |
| Minted to | `msg.sender` of the creation transaction, once, in the constructor |
| Constructor arguments | none |
| Owner / admin | none |

## What the token does

`MADToken` inherits OpenZeppelin v5.4.0 `ERC20` unchanged and adds nothing but the fixed mint in its
constructor. It has:

- standard `transfer`, `approve`, `transferFrom`, `allowance`, `balanceOf`, `totalSupply`,
  `name`, `symbol`, `decimals`, with `Transfer` and `Approval` events;
- no owner, no minter role, no `mint`, no `burn`, no pause, no blacklist, no fee or tax on transfer,
  no upgradeability, no `delegatecall`, no `selfdestruct`;
- a supply that is minted exactly once and can never grow. Nothing in the contract reaches `_mint`
  after construction.

Because no transfer path is taxed or gated, every launch flow (factory to distributor, distributor
to claimant, pool seed, swaps in either direction) moves exactly the amount requested, and no
address needs to be exempted. The token therefore takes no `$factory`, `$poolManager` or
`$launchNumber` constructor argument.

## Design assumptions

- **Deployer is the factory.** The brief asks for the whole supply minted to the deployer. On this
  launch the deployer is IdentityMD's ProjectFactory (`launchCustom`), so the factory receives the
  supply and distributes it itself: 10% to the launch's MerkleDistributor (the swarm), 80% to the
  single-sided Uniswap v4 pool paired with FWA, and 10% to `economics.remainderTo`. The token does
  not know or care about any of those addresses.
- **No external calls in the constructor.** The constructor only writes storage and emits one
  `Transfer`, so it deploys on an empty chain and under CREATE2 from the factory.
- **Standard OpenZeppelin semantics.** Transfers to the zero address and approvals to the zero
  spender revert; a `type(uint256).max` allowance is not decremented; transfers of zero succeed;
  errors are the ERC-6093 custom errors (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`,
  `ERC20InvalidReceiver`, `ERC20InvalidSpender`).
- **No ETH handling.** The contract has no `receive` or `fallback`; sending ETH or an empty call to
  it reverts.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Contract name recorded by the launch | `MADToken` (8 characters) |
| `constructorArgs` | `[]` |
| `token.totalSupply` (minor units) | `1000000000000000000000000000` |
| `token.decimals` | `18` |
| Compiler | solc `0.8.26`, optimizer on (200 runs), EVM `cancun`, `bytecode_hash = "none"` |

Launch-decided values that are not the token's concern but belong to the manifest step: pair
currency FWA `0xa0df17b5ac76ababa36e1450e2cbcd18a620c845`, pool fee `12500`, tick spacing `60`,
economics `{"poolBps":8000,"initialMarketCapWei":"2000000000000000000000000","remainderTo":"0x1ee3ffadfe138415a2ddaedeebe5f46616fa413d"}`.
This repository does not contain a `launch.json`; the manifest step writes it after acceptance.

## After launch

There is nothing to set. The token has no owner-settable configuration, no settings and no
privileged functions. No post-deployment transaction is required or possible from a privileged
party.

## Operational responsibilities

- **Holders** are responsible for their own keys and allowances. There is no recovery mechanism:
  tokens sent to a wrong address, or to the token contract itself, cannot be retrieved by anyone.
- **The factory / deployer** is responsible for distributing the supply it receives. The token
  cannot claw anything back once it has left an address.
- **Nobody** can pause, freeze, mint, burn another holder's tokens, or change any parameter. There
  is no admin key to secure, rotate or hand to a multisig.
- **Explorer verification** of the deployed source is an open item for the network's deployer after
  launch; this repository does not deploy, broadcast or hold keys.

## Repository layout

```
foundry.toml                 compiler pins (solc 0.8.26, bytecode_hash = "none"), fmt settings
remappings.txt               forge-std and @openzeppelin/contracts remappings
src/MADToken.sol             the token
test/MADToken.t.sol          unit and fuzz tests
lib/forge-std/               vendored forge-std 1.17.0 (plain files, MIT/Apache-2.0)
lib/openzeppelin-contracts/  vendored OpenZeppelin Contracts v5.4.0 (plain files, MIT)
```

Dependencies are vendored as ordinary files, not git submodules, so the project builds offline.

## Building and testing

```
forge build
forge test
forge fmt --check
```

The tests cover: metadata and supply; the constructor minting the whole supply to an EOA deployer
and to a contract deployer; transfer and `transferFrom` success paths including events, whole
balance, zero amounts, self-transfer and infinite allowance; failure paths for insufficient balance,
insufficient allowance, zero receiver and zero spender; that no plausible admin selector exists or
changes state when called by a stranger or by the deployer; that ETH and empty calls are rejected;
and fuzzed conservation of supply across single, chained and allowance-based transfers.

## Security notes

Tests passing do not constitute an audit. The contract is a thin wrapper over OpenZeppelin's audited
`ERC20`, with no custom transfer logic, which keeps the attack surface to that library. Items from
the security checklist that apply here: access control (none needed, no privileged functions);
events on every state change (inherited); input validation (inherited zero-address checks); no
proxies, signatures, oracles, external token handling or delegatecall. An independent adversarial
review before release remains good practice for any contract that will hold value.
