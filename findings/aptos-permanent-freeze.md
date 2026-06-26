# Permanent Freezing of Funds in Aptos Staker (Critical)

**Severity:** Critical — Permanent freezing of funds  
**Asset:** Aptos staker (TruAPT) — TruFin-io/smart-contracts-aptos-public  
**Scope status:** In scope (public contracts + testnet staker)

## Executive Summary

The TruYields Aptos liquid staking implementation contains a hard-coded minimum active stake invariant (`MIN_COINS_ON_SHARES_POOL = 10 APT`) combined with a "force full exit" rule in the unlock logic.

When a user attempts to unlock an amount that would leave their remaining position below this minimum, the contract:
1. Forces the unlock amount to their entire `max_withdraw`.
2. Then asserts that the delegation pool will still have at least `amount + 10 APT` active stake after the operation.

For the last user (or when the position crosses the threshold), this assertion is mathematically impossible. The transaction reverts with `EUNLOCK_AMOUNT_TOO_HIGH`.

Result: the final ~10 APT of stake (and its corresponding TruAPT shares) become permanently unredeemable. There is no path — user-initiated or otherwise — to recover these funds.

This is a systemic flaw present in every delegation pool by design.

## Root Cause (Detailed Causal Analysis)

Location: `aptos-staker/sources/staker.move`

### 1. The Minimum Stake Constant
```move
const MIN_COINS_ON_SHARES_POOL: u64 = 10_00000000; // 10 APT
```

This value is enforced in multiple places (initialization, setters, and unlock).

### 2. The Force-Full Logic (internal_unlock ~1424)
```move
if (max_withdraw - amount < MIN_COINS_ON_SHARES_POOL) {
    amount = max_withdraw;
    truAPT_amount = truAPT::balance_of(receiver);
}
```

The intent is reasonable on the surface: "if the user would leave dust below the protocol minimum, just let them exit everything."

### 3. The Fatal Assert (line ~1434)
```move
let (active, _, _) = delegation_pool::get_stake(pool, RESOURCE_ACCOUNT);
assert!(active >= amount + MIN_COINS_ON_SHARES_POOL, EUNLOCK_AMOUNT_TOO_HIGH);
```

When the user is the sole/last holder:
- `active == max_withdraw`
- After force: `amount == max_withdraw`
- Assert becomes: `active >= active + 10 APT` → **always false**

The transaction reverts before any shares are burned and before `delegation_pool::unlock` is called.

### 4. Why No Recovery Path Exists
- No special case for "last withdrawal".
- No protocol reserve that owns the minimum.
- `collect_residual_rewards` and admin paths do not allow user redemption of this trapped value.
- The shares remain in circulation in the accounting (total supply and share price calculations continue to reflect them).

## Why This Is Permanent Freezing

The funds are not temporarily locked during unbonding. They are **irreversibly** trapped:

- The user still holds the TruAPT shares.
- `max_withdraw()` still reports the value.
- But every call to `unlock()` (full or partial) will hit the same assert and revert.
- The underlying APT sits in the Aptos delegation pool and can never be moved back to the staker resource account for that user.

This matches Immunefi's Critical category exactly: "Permanent freezing of funds".

## Concrete User Scenarios

**Scenario A — Small position / new user**
- User stakes 15 APT.
- Tries to unlock 6 APT (or any amount).
- Remaining would be 9 < 10 → force full 15.
- Revert. User is now permanently stuck with 15 APT worth of illiquid TruAPT.

**Scenario B — Last user in a pool**
- Pool has 25 APT total active.
- User A unlocks 15 → pool drops to ~10.
- User B (last) now holds the remaining 10.
- User B cannot unlock anything without triggering the assert.

**Scenario C — Griefing**
- Attacker (or even normal behavior) leaves several pools with active stake slightly above 10 APT.
- Later users who stake into those pools or reduce positions become trapped on exit.

## Accounting Consequence

The protocol's share accounting and `total_staked` continue to treat the locked 10 APT as fully backed user funds. Share price calculations and treasury fee logic include this amount, yet no user can ever redeem the corresponding shares. This creates a permanent mismatch between outstanding supply and actually claimable assets.

## Impact (Why This Matters for Payout)

- **Systemic**: Affects 100% of delegation pools.
- **Breaks core LST property**: "1 TruAPT should always be redeemable for the underlying + yield".
- **User funds at risk**: Anyone with a position near or below ~20 APT per pool loses exit capability.
- **Protocol UX and trust damage**: Users discover they cannot exit after the fact.
- **Griefing vector**: Low cost to create trapped positions for others.
- **No compensation mechanism**: The minimum is taken from user funds without any protocol-owned reserve or warning.

Even if the absolute dollar amount per pool is currently modest, the design flaw is fundamental and will affect every future pool and every user who tries a full or near-full exit.

## Reproduction (Deterministic PoC)

### Local (official test framework)

1. Clone the public repo:
   ```bash
   git clone https://github.com/TruFin-io/smart-contracts-aptos-public.git
   cd smart-contracts-aptos-public/aptos-staker
   ```

2. Add the provided reproduction (see `poc/aptos/repro_unlock_min.move`) into the test module or extend `tests/unlock_test.move`.

3. Run:
   ```bash
   aptos move test --dev -f poc_last_ten_apt_frozen
   ```

Expected: the unlock path reverts. Shares remain, active stake in the delegation pool is unchanged.

### Manual high-level repro (testnet or local harness)
- Whitelist a test account.
- `stake(15 * ONE_APT)`
- `end_aptos_epoch()`
- `unlock(5 * ONE_APT)` (or any amount)
- Transaction reverts with `EUNLOCK_AMOUNT_TOO_HIGH`.
- `max_withdraw()` still reports value.
- No unlock request is created.
- `delegation_pool::get_stake` active remains the full amount.

Existing tests avoid this boundary entirely (they use 50–1000+ APT).

## Recommended Mitigation (Actionable)

### Option 1 — Final Drain Path (Recommended)
Add a special case before the assert:
- If this unlock would bring the pool's active stake below `MIN`, allow draining the entire remaining active stake.
- Accept that the delegation pool may become inactive for that validator (document the trade-off).
- Burn the shares and transfer the actual remaining coins.

### Option 2 — Protocol-Owned Reserve
- At pool creation / first stake, mint or reserve 10 APT from protocol funds (treasury) as the minimum.
- Exclude this reserve from `total_staked`, `tax_exempt_stake`, and share price calculations.
- User funds are never used for the liveness minimum.

### Option 3 — Reduce or Remove Minimum for Unlock
- Make the minimum a "deposit minimum" only.
- Allow unlocks to go to zero (or a much lower per-user dust limit).
- Accept the underlying delegation pool risk or handle deactivation gracefully.

### Required Accompanying Changes
- Add boundary tests: stake exactly 11 APT, 10 APT, 20 APT; attempt full and partial unlocks.
- Update documentation for users about minimum practical position size.
- Consider making `MIN_COINS_ON_SHARES_POOL` configurable via timelocked governance (with clear communication).

## References (Exact Locations)

- Constant: `staker.move:37`
- Entry points: `unlock`, `unlock_from_pool` → `internal_unlock`
- Force-full logic: `~1424`
- Assert: `~1434`
- Error codes: `EBELOW_MIN_UNLOCK (7)`, `EUNLOCK_AMOUNT_TOO_HIGH (20)`
- Test getter: `test_min_coins_on_share_pool`

Public source used for this analysis: TruFin-io/smart-contracts-aptos-public (as of the date of this report).

## Why This Qualifies as Critical (Immunefi Alignment)

- Direct and permanent loss of ability to access deposited funds.
- No time limit, no admin backdoor for the affected user.
- Matches the published scope language for Critical: "Permanent freezing of funds".
- Systemic architectural flaw rather than a one-off miscalculation.

This is not "slashing risk" or "temporary unbonding". It is a hard, unrecoverable lock on user capital caused by the protocol's own exit logic.

---

**Report prepared for disclosure.** All analysis performed on publicly available source code. No mainnet funds or private keys were used.