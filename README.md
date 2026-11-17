# Morpheus — DistributorV2 aToken-donation yield inflation (PoC)

Foundry proof of concept for a Morpheus bug bounty report. Anyone can donate
aTokens to the Distributor, inflating a pool's measured yield at the next
distribution and diverting MOR emissions toward the attacker's pool — the
`isDepositTokenAdded` guard (public issue #64's fix) cannot see an external
transfer, so no second pool is needed.

- **Target:** Distributor `0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A` (Ethereum,
  Appendix A)
- **Fork:** Ethereum mainnet, pinned to block **26434871**
- **Result:** 147k USDT stake + 367 aUSDT/day donation → USDT tranche 54 → 1,037
  MOR; attacker nets ~$187/day; stETH stakers lose ~910 MOR/day (~$642/day).
  No privileged accounts are used.

## Run (one command, from a clean clone)

```sh
forge test
```

Requires [Foundry](https://getfoundry.sh/) (forge 1.9+). `forge-std` is vendored
under `lib/`, so no install step is needed. The fork RPC defaults to
`https://eth.drpc.org`; override with `ETH_RPC_URL`:

```sh
ETH_RPC_URL=https://eth.llamarpc.com forge test
```

## What the tests assert

- `testDonationInflatesYieldShare` — the donation is net profitable in MOR
  (incremental gain > donation cost), the USDT pool's MOR share jumps >5x vs the
  no-donation control, and the stETH stakers' share falls.
- `testDonationProfitableAtHighRebase` — the donation stays net profitable even
  at the top of the observed daily Lido rebase range (0.44 stETH).

Harness notes (documented in the test header): Chainlink feeds are mocked to
their pinned-block answers with a fresh `updatedAt` across the warped day
(simulating normal feed updates); one day of yield is simulated as mainnet
produces it (real Aave reserve index updates + a 0.34 stETH Lido rebase).
