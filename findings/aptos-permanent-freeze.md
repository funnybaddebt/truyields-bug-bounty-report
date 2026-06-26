# Permanent Freezing of Funds via MIN_COINS_ON_SHARES_POOL

**Severity:** Critical (Permanent freezing of funds)

**Asset:** Aptos staker — TruAPT vault  
**Public source:** https://github.com/TruFin-io/smart-contracts-aptos-public

## Root Cause

The contract defines a minimum active stake that must be preserved in every delegation pool:

```move
const MIN_COINS_ON_SHARES_POOL: u64 = 10_00000000; // 10 APT
```

In `internal_unlock` (staker.move):

- An unlock amount must be at least `MIN_COINS_ON_SHARES_POOL`.
- If executing the requested unlock would leave the user below the minimum (`max_withdraw - amount < MIN`), the code forces `amount = max_withdraw`.
- It then performs:

```move
let (active, _, _) = delegation_pool::get_stake(pool, RESOURCE_ACCOUNT);
assert!(active >= amount + MIN_COINS_ON_SHARES_POOL, EUNLOCK_AMOUNT_TOO_HIGH);
```

For any user who is the sole or last staker in a pool (or whose withdrawal crosses the threshold), `active == max_withdraw`. The assertion `active >= max_withdraw + 10 APT` is impossible and reverts.

The shares are never burned. The APT never moves out of the delegation pool. There is no alternative exit path.

## Why This Is Permanent

- No admin function, residual claim, or withdrawal path bypasses the check for user-initiated exits.
- The minimum is required for the underlying Aptos delegation pool to remain active.
- The accounting (total_staked, share price, supply) continues to treat the locked amount as fully backed.
- Once trapped, the funds have no redemption path for the affected user(s).

## Impact

- Every delegation pool permanently traps at least 10 APT of user value.
- Users with positions near or below ~20 APT are at risk of partial or full loss of exit capability.
- The liquid staking token guarantee is broken by construction.
- Griefing is trivial: reduce a pool close to the minimum and later participants cannot fully exit.

This constitutes permanent freezing of funds and renders the contract unable to be cleanly drained by users.

## Reproduction

Stake a modest amount above the minimum as a whitelisted account, then attempt an unlock that would leave less than 10 APT:

- Expected: revert with `EUNLOCK_AMOUNT_TOO_HIGH` (or `EBELOW_MIN_UNLOCK`).
- Observed: TruAPT balance unchanged, no pending inactive stake created, delegation pool active stake unchanged.

A self-contained reproduction test is available under `poc/aptos/repro_unlock_min.move`.

Existing test coverage uses large stakes (50–1000 APT) and never exercises the boundary where `max_withdraw - amount < MIN`.

## Recommended Fix

- Provide a special case for the final withdrawal that drains the pool entirely (accepting that the delegation pool may become inactive).
- Or isolate the 10 APT minimum as a protocol reserve that is never represented in outstanding user shares.
- Add test cases that explicitly cover staking near the minimum and full/partial exit attempts.

## References

- `aptos-staker/sources/staker.move:37` (constant)
- `aptos-staker/sources/staker.move:1407-1450` (internal_unlock and force-full logic)
- Errors: `EBELOW_MIN_UNLOCK`, `EUNLOCK_AMOUNT_TOO_HIGH`
- Tests: unlock_test.move and related setup modules
- Underlying requirement comes from Aptos `delegation_pool` module.