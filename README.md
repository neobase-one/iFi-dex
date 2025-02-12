# iFi Dex
Decentralized exchange with concentrated liquidity, incentives, and liquidity fusion for the [Althea L1](https://www.althea.net/) blockchain

Frontend to be available at https://althea.link

The iFi dex is a fork of [CrocSwap](https://github.com/CrocSwap/CrocSwap-protocol) with a few major changes. Discussed in this [blog post](https://blog.althea.net/introducing-the-ifi-dex/)


1) Events have been added for all Dex actions, allowing for much faster backends and making it possible to fully interact with the dex without relying on an ETH archive node and enormous subgraph. Swaps can now be carried out with only a standard ETH RPC and a moderate amount of event syncing practical on embedded devices.
2) An incentives system for ambient and concentrated liquidity have been added.
3) Timelocks have been removed from governance roles as they are expected to be called from Althea L1 chain governance, which already has a long voting period
4) The Solidity version has been updated and VIA IR enabled to create room in the main contract for (1) and (2)

As discussed in the above blog post, our goal with the iFi dex was to keep the incredible flexibility and feature set of Ambient Dex, while removing some of it's sharp edges as far as operating a backend / interacting with the Dex without a high-resource centralized server. This is essential for Althea L1's machine-to-machine payment focus. Likewise the liquidity incentives were added to better utilize Ambient's existing feature set of layered liquidity types in a single pool (which we call Liquidtiy Fusion).

These changes have the effect of increasing the gas usage of the swaps by about 10% on swaps and 30% for liquidity actions. Due to Ambient dex's extremely good baseline gas efficiency this increase mostly serves to bring swap costs in line with Uniswap.

## What is Liquidity Fusion?

Liquidity Fusion, refers to the flexibility of Ambient dex and now iFi dex pools. Where Ambient liquidity (Uniswap v2 style), Concentrated liquidity (Uniswap v3 style), and Knockout liquidity (limit orders as liquidity, unique to Ambient and it's forks) can exist in the same pool. Effectively a swap over a pool acts closer to a swap aggregator would over other DEX protocols, aggregating multiple types of liquidity in the same swap.

The iFi dex incentives mechanism is intented to help make better use of this existing feature from Ambient by incentivizing Ambient liquidity (uniswap v2 style) which is otherwise not very attractive to LP. In Ambient dex Ambient liquidity is mostly utilized as a holding location for accumulated fees as a concentrated LP. 

## How does the incentive system work?

The iFi dex incentive system is a split design, meaning most of the incentive logic is not within the main iFi dex contract. Instead it is located in external incentives contracts. The iFi dex exposes counters for concentrated and ambient liquidity added and removed as well as concentrated liquidity rewards accumulated.

These counters can then be used by external contracts to provide incentives that are permissionless from the perspective of the core Dex itself, this also allows incentives contracts to be upgraded independently from the main dex.

This does come with some downsides, namely that the callflow for the user can be more complex. Requiring the user to go make a call on the dex, then the rewards contract separately. This can be simplified by using Ambient's router contract functionality, effectively allowing a rewards contract to handle liquidity on behalf of a user.

## Installation

Clone the repository. In the repository home directory run the following commands:

    $ yarn install
    $ npx hardhat compile
    
To verify that the code is functioning run:

    $ npx hardhat test

Test coverage can be run with



## Documentation

Primary docs can be found at [our Gitbook](https://docs.ambient.finance)

Additional technical documentation can be found

* [Repo Layout](docs/Layout.md): Top-level overview of the Solidity source files in the project.
* [Control Flow](docs/ControlFlow.md): Illustrated flow charts mapping the smart contract logic associated with common CrocSwap operations.
* [Encoding Guide](docs/Encoding.md): Technical specification for clients outlining how to encode arguments to the CrocSwap contract methods that don't use standard Solidity args.

## Risks

Users of the CrocSwap protocol should be aware of the implicit risks to the protocol design. Among other major risk sare

* Protocol Risk - Although carefully reviewed the protocol could have an implementation error that leads to loss of funds
* [Governance Risk](./docs/GovernanceRoles.md) - CrocSwap governance has fairly extensive powers, and users should fully trust the entities holding governance roles.
* [Token Risk](./docs/TokenModel.md) - CrocSwap expects has fairly stringent conformance requirements to guarantee safe and defined behavior. Users interacting with pools on non-compliant or malicious tokens risk loss of funds.
* [Upgrade Risk](./docs/UpgradeSafety.md) - CrocSwap allows for smart contract code upgrade. Any upgrade represents a risk to the entire protocol and users funds if implemented incorrectly. Users should monitor all proposed upgrades and trust the governance process for approving upgrade proposals.
