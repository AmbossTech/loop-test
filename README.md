# amboss-loop-lab

Test bench for Lightning Labs Loop, for [AMB-3190](https://linear.app/amboss/issue/AMB-3190/test-loop-on-chain-receive-in-a-local-regtest-setup) and the on-chain payments work in [AMB-3169](https://linear.app/amboss/issue/AMB-3169) / [AMB-3170](https://linear.app/amboss/issue/AMB-3170).

Two things live here:

1. `quote.sh`, which reads real limits and fees off the public Loop servers. No node, no docker, no L402 token. Runs in about ten seconds.
2. A signet stack running our production litd image with the loop sub-daemon on, for the actual receive flow.

## Why signet and not regtest

The upstream [loop regtest docs](https://github.com/lightninglabs/loop/blob/master/regtest/README.md) tell you to pull `lightninglabs/loopserver:latest`. That image is not public any more:

```
$ docker pull lightninglabs/loopserver:latest
Error response from daemon: pull access denied for lightninglabs/loopserver,
repository does not exist or may require 'docker login'
```

It is not in the `lightninglabs` Docker Hub namespace, and an anonymous registry token gets `UNAUTHORIZED` on the tag list while `lightninglabs/loop` in the same namespace lists fine. So the docs are stale and local regtest is not an option without asking Lightning Labs for access.

Signet is the better answer anyway. Loop runs a public server on it, so we test against the real thing rather than a stripped-down stub:

| Network | Server |
|---|---|
| mainnet | `swap.lightning.today:11010` |
| testnet | `test.swap.lightning.today:11010` |
| signet | `signet.swap.lightning.today:11010` |

Loop picks the server from the network on its own, so there is no server address to configure.

Note this is plain signet, not mutinynet. Mutinynet is a custom signet with its own chain, and there is no Loop server on it.

## quote.sh

```
./quote.sh mainnet
./quote.sh signet
```

`LoopInTerms`, `LoopInQuote`, `LoopOutTerms` and `LoopOutQuote` sit behind aperture's auth whitelist, so they answer without a paid L402 token. That is why this works with nothing but grpcurl.

Needs `grpcurl` and `jq` (`brew install grpcurl jq`). Protos are fetched on first run into `.protos/`, which is gitignored.

Saved output is in `findings/`.

### What it told us, mainnet, 15 Sep 2026

| | Loop In (we receive) | Loop Out (we send) |
|---|---|---|
| Fee | 0.18% + 68 sat | 0.1% + 44 sat |
| Min | 250,000 sat | 250,000 sat |
| Max | 240,000,000 sat | 240,000,000 sat |
| Prepay | none | 30,000 sat |

Both formulas fit every sampled amount exactly, so this is the real schedule and not a sample.

Three things worth knowing:

1. **The 250,000 sat minimum is a product constraint.** We cannot receive small on-chain payments through Loop at all. The Boltz forks go down to 25,000 (Coinos) and 50,000 (SATS Routing).
2. **Loop is not the cheapest on receive.** At 500,000 sat, Loop In costs 968 sat against 667 for SATS Routing. Loop's rate is 0.18% and theirs is 0.1%. Loop only wins below about 124,000 sat, which is under its own minimum, so in practice it never wins on receive rate.
3. **Loop is much cheaper on send.** 0.1% against 0.5% on the forks, and its ceiling is 2.4 BTC against 0.05 BTC on SATS Routing and 0.006 BTC on Coinos.

Signet quotes match mainnet on Loop In, but Loop Out on signet carries a much larger base (0.1% + 8,135 sat). Use signet for flow, mainnet for price.

## The signet stack

```
./loop-lab up
./loop-lab sync        # wait for bitcoind then lnd
./loop-lab info
```

Two containers. `bitcoin/bitcoin:29.0` on signet, and `lightninglabs/lightning-terminal:v0.17.0-alpha`, the same tag the `litd-node` chart pins in production.

`conf/lit.conf` mirrors the chart's configmap with two deliberate differences:

```
loop-mode=integrated     # chart has disable
loop.loopdir=/data/.loop # chart has no loop config at all
```

The second line is the point of the exercise. Loop defaults its data directory to `~/.loop`, which in our pods is not on the PVC. The L402 token lives there, and per Lightning Labs' own docs, losing it means the only way out of a static-address contract is to wait for the 14,400 block timeout, roughly 100 days. Verified working here:

```
$ docker exec loop-lab-litd ls -d /data/.loop /root/.loop
/data/.loop
ls: /root/.loop: No such file or directory
```

The chart will need `loop.loopdir` and probably `loop.databasebackend=postgres`, mirroring what `taproot-assets.tapddir` already does.

### Bootstrapping inbound liquidity

Loop In means the server pays us over Lightning, so we need inbound capacity before we can receive anything. A fresh node has none. Order:

1. `./loop-lab addr` and fund it from a signet faucet.
2. `./loop-lab open-channel 2000000` opens to the Loop signet swap server (`020b7dab...5e2257`, read from a `LoopOutQuote` `swap_payment_dest`). That gives us outbound.
3. `./loop-lab inbound 500000` loops out, turning outbound into inbound.
4. Now Loop In has room to work.

Step 3 uses `--fast`. Without it the server may batch and sit on the swap for up to 30 minutes.

### The receive flows

Two shapes, and choosing between them is an open product question.

```
./loop-lab static-new          # one reusable address, forever
./loop-lab static-deposits
./loop-lab static-in

./loop-lab in-external 500000  # fresh address for one specific payment
```

The reusable address is simpler to operate but every deposit at it looks identical, so we cannot tell which payment belongs to which invoice and would be reconciling on amount and timing. A per-payment address gives attribution for free, the way a BOLT11 payment hash does today, at the cost of a swap per payment and an amount that has to match.

### Restart safety

```
./loop-lab restart-test
```

Restarts litd and re-lists the L402 token and the deposits. Both must survive. If they don't, `loop.loopdir` isn't landing on the volume.

## Fees we do not pay on receive

From `looprpc/client.proto` on `InQuoteResponse.htlc_publish_fee_sat`:

> If a miner fee of 0 is returned, it means the external_htlc flag was set for a loop in and the fee estimation was skipped.

When a third party funds the HTLC, they pay the on-chain fee. Our cost on receive is the server swap fee only.

## Macaroon permissions

From [`looprpc/perms.go`](https://github.com/lightninglabs/loop/blob/master/looprpc/perms.go). None of these are on-chain spend, so extending `litdWantedPermissions` in `amboss-rails-api/src/modules/daemon/litd/litd.ts` does not break the Rails rule that issued macaroons never grant on-chain spend.

| Call | Needs |
|---|---|
| `GetLoopInQuote`, `GetLoopInTerms` | `swap:read`, `terms:read`, `loop:in` |
| `LoopIn`, `StaticAddressLoopIn` | `swap:execute`, `loop:in` |
| `NewStaticAddress`, `ListStaticAddressDeposits` | `swap:read`, `loop:in` |
| `WithdrawDeposits` | `swap:execute`, `loop:in` |
| `FetchL402Token` | `auth:write` |

The sweep that genuinely needs on-chain access is Loop Out, the send side, which is a separate question for later.

## What this bench cannot tell us

Production mainnet nodes run neutrino. This stack runs bitcoind. Loop needs confirmation and spend notifications for deposits, so a green run here does not prove neutrino works. That needs checking separately before loop is enabled on a real node.

## Teardown

```
./loop-lab down    # keep chain data
./loop-lab nuke    # delete volumes, resync from scratch
```
