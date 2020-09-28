# MakerDao
MakerDao是一个去中心化的金融系统，主要提供稳定币Dai，Dai的稳定由已发行的Token质押作为保证，比如ETH、USDT等。Maker系统为了方便，加入系统的资产首先都要转换成一比一的代币，比如ETH转换成WETh，WETH作为资产抵押。每个人都可以用自己的手中的资产抵押借Dai，借贷率拒绝于手中资产类型的稳定性，资产的稳定性越高，借到的Dai越多，反之越少。这类型银行房产抵押贷款，你的房子价值越稳定，可以借到的款越多。若资产发生暴跌，为了保证Dai的稳定性，会触发资产清算，将资产拍卖抵债（回购的Dai会被销毁)，还要扣除手续费（目前为13%)，完成抵债后若还有资产剩余，则退还给借贷者。当然也可能发生资不抵债的情况，这时系统归还剩余的资产，保证Dai价格的稳定性。若系统没有Dai归还所剩余的债，就会启动MKR币拍卖，MKR是治理者拥有的一种投票的币。拍卖的MKR由系统增发。系统允许良好时，拍卖Dai回购MKR进行销毁，保证MKR的稳定性。
由此可见，Dai不是绝对与美元一比一锚定，仍然有贬值风险，不过只要控制资产的抵押率在安全范围内，Dai就是稳定的。这让我想到黄金，其实我们的纸币也不会绝对稳定，如果黄金价格波动过大，超过预期范围，也会贬值，无论是美元还是人民币。纸币必须依附于等价值的实物，这和Dai很相似。

我没学过金融，断断续续理解MakerDao，不过还是感觉专业知识不足，若理解有误，请多多指教。希望有金融领域知识的同学一起分析这个有趣的项目。



# Multi Collateral Dai
[![Build Status](https://travis-ci.com/makerdao/dss.svg?branch=master)](https://travis-ci.com/makerdao/dss)
[![codecov](https://codecov.io/gh/makerdao/dss/branch/master/graph/badge.svg)](https://codecov.io/gh/makerdao/dss)

This repository contains the core smart contract code for Multi
Collateral Dai. This is a high level description of the system, assuming
familiarity with the basic economic mechanics as described in the
whitepaper.

## Additional Documentation

`dss` is also documented in the [wiki](https://github.com/makerdao/dss/wiki) and in [DEVELOPING.md](https://github.com/makerdao/dss/blob/master/DEVELOPING.md)

## Design Considerations

- Token agnostic
  - system doesn't care about the implementation of external tokens
  - can operate entirely independently of other systems, provided an authority assigns
    initial collateral to users in the system and provides price data.

- Verifiable
  - designed from the bottom up to be amenable to formal verification
  - the core cdp and balance database makes *no* external calls and
    contains *no* precision loss (i.e. no division)

- Modular
  - multi contract core system is made to be very adaptable to changing
    requirements.
  - allows for implementations of e.g. auctions, liquidation, CDP risk
    conditions, to be altered on a live system.
  - allows for the addition of novel collateral types (e.g. whitelisting)


## Collateral, Adapters and Wrappers

Collateral is the foundation of Dai and Dai creation is not possible
without it. There are many potential candidates for collateral, whether
native ether, ERC20 tokens, other fungible token standards like ERC777,
non-fungible tokens, or any number of other financial instruments.

Token wrappers are one solution to the need to standardise collateral
behaviour in Dai. Inconsistent decimals and transfer semantics are
reasons for wrapping. For example, the WETH token is an ERC20 wrapper
around native ether.

In MCD, we abstract all of these different token behaviours away behind
*Adapters*.

Adapters manipulate a single core system function: `slip`, which
modifies user collateral balances.

Adapters should be very small and well defined contracts. Adapters are
very powerful and should be carefully vetted by MKR holders. Some
examples are given in `join.sol`. Note that the adapter is the only
connection between a given collateral type and the concrete on-chain
token that it represents.

There can be a multitude of adapters for each collateral type, for
different requirements. For example, ETH collateral could have an
adapter for native ether and *also* for WETH.


## The Dai Token

The fundamental state of a Dai balance is given by the balance in the
core (`vat.dai`, sometimes referred to as `D`).

Given this, there are a number of ways to implement the Dai that is used
outside of the system, with different trade offs.

*Fundamentally, "Dai" is any token that is directly fungible with the
core.*

In the Kovan deployment, "Dai" is represented by an ERC20 DSToken.
After interacting with CDPs and auctions, users must `exit` from the
system to gain a balance of this token, which can then be used in Oasis
etc.

It is possible to have multiple fungible Dai tokens, allowing for the
adoption of new token standards. This needs careful consideration from a
UX perspective, with the notion of a canonical token address becoming
increasingly restrictive. In the future, cross-chain communication and
scalable sidechains will likely lead to a proliferation of multiple Dai
tokens. Users of the core could `exit` into a Plasma sidechain, an
Ethereum shard, or a different blockchain entirely via e.g. the Cosmos
Hub.


## Price Feeds

Price feeds are a crucial part of the Dai system. The code here assumes
that there are working price feeds and that their values are being
pushed to the contracts.

Specifically, the price that is required is the highest acceptable
quantity of CDP Dai debt per unit of collateral.


## Liquidation and Auctions

An important difference between SCD and MCD is the switch from fixed
price sell offs to auctions as the means of liquidating collateral.

The auctions implemented here are simple and expect liquidations to
occur in *fixed size lots* (say 10,000 ETH).


## Settlement

Another important difference between SCD and MCD is in the handling of
System Debt. System Debt is debt that has been taken from risky CDPs.
In SCD this is covered by diluting the collateral pool via the PETH
mechanism. In MCD this is covered by dilution of an external token,
namely MKR.

As in collateral liquidation, this dilution occurs by an auction
(`flop`), using a fixed-size lot.

In order to reduce the collateral intensity of large CDP liquidations,
MKR dilution is delayed by a configurable period (e.g 1 week).

Similarly, System Surplus is handled by an auction (`flap`), which sells
off Dai surplus in return for the highest bidder in MKR.


## Authentication

The contracts here use a very simple multi-owner authentication system,
where a contract totally trusts multiple other contracts to call its
functions and configure it.

It is expected that modification of this state will be via an interface
that is used by the Governance layer.
