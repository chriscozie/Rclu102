# SwarmHFT v2 — swarm tick scalper for Exness MT5

`MQL5/Experts/SwarmHFT.mq5` is an Expert Advisor. Five independent agents vote on every tick. Each agent's vote is weighted by its learned track record. A trade opens only when:

1. the weighted consensus clears a threshold,
2. enough agents agree on the direction, and
3. the target distance is at least 3× the full trading cost (spread plus commission).

## 1. Profitability — read this first

**No parameter set can guarantee a profit.** Retail tick-scalping lives or dies on cost relative to volatility. This EA is designed to refuse trades whose edge does not cover cost, but you still have to prove it on your own Exness account's real ticks. Follow section 6 before you risk money.

**This is not true HFT.** True HFT means co-located servers and microsecond execution. MT5 on Exness gives about 1–30 ms on a VPS near the server, and much more from a Kampala connection. This EA is a **low-latency tick scalper** that holds trades for seconds to 5 minutes. Do not run it from a home PC or laptop; use a VPS.

### Break-even win rate (why the cost filter matters)

Express all distances in multiples of ATR(M1):
- *TP* = take-profit distance
- *SL* = stop-loss distance
- *c* = round-trip cost (spread plus commission) ÷ ATR

The break-even win rate is:

&nbsp;&nbsp;&nbsp;&nbsp;**p_BE = (SL + c) / (TP + SL)**

| Symbol (Raw Spread) | Assumed ATR(M1) | Cost per round trip | c | TP / SL | p_BE |
|---|---|---|---|---|---|
| XAUUSD | USD 2.00 | spread USD 0.12 + commission USD 0.07 = USD 0.19 | 0.095 | 0.80 / 0.90 | **58.5 %** |
| EURUSD (12:00–16:00) | 2.5 pip | spread 0.1 pip + commission 0.7 pip = 0.8 pip | 0.32 | 1.10 / 1.20 | **66.1 %** |

The XAUUSD commission works out as USD 7.00 per lot round trip ÷ 100 oz per lot = USD 0.07 of price.

**Verdict:**
- **XAUUSD is the primary market.** Its cost-to-volatility ratio is about 3× better than EURUSD's.
- **EURUSD is marginal.** It needs a win rate of about 66 % before break-even and trailing exits are counted. Run it only if the real-tick backtest *and* demo forward test both pass.
- **Do not use Exness Standard or Standard Cent accounts.** Their spreads are too wide for this EA, and the spread/ATR filter will block most entries anyway.
- **Use Raw Spread or Zero.** On Zero, set `InpCommissionPerLot` to the round-trip commission your account shows for the symbol.

## 2. The swarm

| # | Agent | Signal logic | Role |
|---|---|---|---|
| 1 | Momentum | Net mid move over `A1_Ticks` > `A1_MoveSpreadMult` × spread, **and** ≥ `A1_DirRatio` of ticks in that direction | Trend-following |
| 2 | Pressure | Ask/bid up-tick vs down-tick imbalance ≥ `A2_Imbalance` over `A2_Ticks`, only if those ticks arrived within `A2_MaxSec` (a burst) | Order-flow proxy |
| 3 | MeanRev | z-score of mid vs its exponentially weighted (EW) mean over `A3_EmaTicks` beyond ±`A3_Z` → **fades** the move | Contrarian veto |
| 4 | Breakout | Mid breaks the high/low of the last `A4_Seconds` by `A4_BreakSpreadMult` × spread | Breakout |
| 5 | Trend | M1 EMA(`A5_Fast`) vs EMA(`A5_Slow`) on the closed bar, with slope and close confirmation | Context bias |

**Consensus:**

&nbsp;&nbsp;&nbsp;&nbsp;S = Σ wᵢ·vᵢ / Σ wᵢ

where vᵢ ∈ {−1, 0, +1} is agent *i*'s vote and wᵢ is its weight. Agents that abstain still count in the denominator, so silence dilutes the score.

An entry needs **|S| ≥ `InpConsensus`** and **agreeing agents ≥ `InpMinAgree`**.

**Learning:** when a position closes, every agent that voted on it is updated:

&nbsp;&nbsp;&nbsp;&nbsp;wᵢ ← clamp( wᵢ · exp(η · vᵢ · dir · R), `InpWMin`, `InpWMax` )

- R is the net result in multiples of the initial risk, clipped to ±2.
- η is `InpLearnRate`.
- After the update, `InpWeightDecay` pulls each weight back towards 1.0.

Agents that voted against a losing trade gain weight. Weights are saved in terminal GlobalVariables (live only), so they survive restarts.

## 3. Parameters

### Risk
| Input | Default | Meaning |
|---|---|---|
| `InpRiskPct` | 0.25 | Equity risked per trade, including commission. Lot size = risk ÷ (SL points × point value + commission) |
| `InpMinLotRiskCapPct` | 1.0 | If the minimum lot over-risks the account, trade it only if its risk is ≤ this % |
| `InpMaxLot` | 5.0 | Hard cap on lot size |
| `InpMaxPositions` | 2 | Maximum open positions for this symbol and magic number |
| `InpDailyLossPct` | 2.0 | Close everything and halt for the day at −2 % of the day's starting equity |
| `InpDailyTargetPct` | 3.0 | Close everything and stop for the day at +3 % (0 = off) |
| `InpMaxDDPct` | 8.0 | Kill switch at 8 % below peak equity. Survives restarts; clear it with `InpResetKill=true` |
| `InpMaxConsecLoss` / `InpCooldownMin` | 4 / 30 | After 4 losses in a row, pause for 30 minutes |
| `InpMaxTradesPerHour` / `InpMinSecBetween` | 20 / 20 | Over-trading throttle |

### Cost and execution
| Input | Default | Meaning |
|---|---|---|
| `InpCommissionPerLot` | 7.0 | Round-trip commission per 1.00 lot, in account currency |
| `InpMinEdgeCostMult` | 3.0 | Skip a trade if TP < 3 × (spread + commission) |
| `InpMaxSpreadATRFrac` | 0.12 | Skip a trade if spread > 12 % of ATR(M1) |
| `InpMaxSpreadPts` | 0 | Absolute spread cap in points (0 = off). Set it per symbol after checking the symbol's digits |
| `InpSlippagePts` | 10 | Maximum price deviation (Exness market execution mostly ignores this) |

### Exits (all in ATR(M1) multiples)
| Input | Gold | EURUSD | Meaning |
|---|---|---|---|
| `InpSL_ATR` | 0.90 | 1.20 | Initial stop loss |
| `InpTP_ATR` | 0.80 | 1.10 | Take profit |
| `InpBE_TriggerR` | 0.50 | 0.50 | At +0.5 R, move SL to entry + commission + 2 points |
| `InpTrailStartR` / `InpTrailATR` | 0.70 / 0.35 | same | Trailing stop |
| `InpMaxHoldSec` | 300 | 420 | Time stop |
| `InpCloseOnReverse` | true | true | Close when consensus turns strongly against the position, even if entries are blocked |

### Swarm
| Input | Default | Meaning |
|---|---|---|
| `InpConsensus` | 0.55 (EURUSD 0.60) | Weighted vote threshold, 0–1 |
| `InpMinAgree` | 3 | Minimum agents agreeing with the direction (of 5) |
| `InpLearnRate` / `InpWeightDecay` | 0.10 / 0.01 | Learning speed / pull back to neutral |
| `InpWMin` / `InpWMax` | 0.2 / 3.0 | Weight bounds, so no agent can dominate or be silenced completely |

### Session (server time; Exness = GMT+0 = EAT −3 h)
| Input | Gold | EURUSD | Meaning |
|---|---|---|---|
| `InpStartHour` / `InpEndHour` | 7 / 20 | 12 / 16 | Trading window. Gold covers London and NY (10:00–23:00 EAT); EURUSD covers the London/NY overlap only |
| `InpBlockFromHHMM` / `InpBlockToHHMM` | 2050 / 2215 | same | Rollover blackout, when spreads blow out |
| `InpFridayStopHour` / `InpMondayStartHour` | 19 / 8 | same | Avoid the weekend gap and thin Monday opens |
| `InpNewsFilter` | true | true | Blocks trading ±15 minutes around high-impact events (MT5 calendar, live only) |

The ready-made presets are `presets/SwarmHFT_XAUUSD_Raw.set` and `presets/SwarmHFT_EURUSD_Raw.set`.

## 4. Install

1. In MT5, open **File → Open Data Folder**. Copy `SwarmHFT.mq5` to `MQL5/Experts/`.
2. Open MetaEditor and press **F7** to compile. The source has **not** been compiled in this repository, so fix any warnings or errors MetaEditor reports.
3. Attach the EA to an **XAUUSD** chart (any timeframe; the agents read ticks and M1 internally) and load the `.set` file.
4. Turn on **Algo Trading**.
5. Run **one chart per symbol**. Give each symbol its own magic number (XAUUSD = 260111, EURUSD = 260112).

## 5. Exness setup

- **Account:** Raw Spread (commission up to USD 3.50 per side per lot) or Zero. Use a hedging account. Netting also works, but reversals then only close the position.
- **Leverage:** risk is controlled by `InpRiskPct`, not leverage. 1:200–1:500 is ample.
- **Server:** run the EA on a VPS. Exness offers a free VPS above an equity threshold (check their current terms), or use any VPS in the same region as your MT5 server, then check the ping in MT5. The EA is designed around a ping under 20 ms.
- **Capital:** at 0.25 % risk with a gold SL of about USD 1.80, a 0.01 lot trade risks about USD 1.87 including commission. The minimum workable equity is therefore about USD 750. With less than that, each min-lot trade risks more than 0.25 % of equity, and trading is only allowed while that risk is ≤ 1 % (`InpMinLotRiskCapPct`).

## 6. Validation protocol (mandatory before live)

1. **Strategy Tester:**
   - Modelling: **"Every tick based on real ticks"**, with Exness real ticks downloaded.
   - Period: at least 6 months.
   - Commission: per your account type (the tester uses the symbol's commission settings).
   - Variable delay: **"Random delay"**. Results without it are fiction for a scalper.
2. **Optimise** on months 1–4. Use **Custom max** as the criterion (the EA's `OnTester` score is PF × recovery factor × √trades ÷ (1 + DD%)). Keep the ranges narrow:
   - `InpConsensus` 0.45–0.70
   - `InpMinAgree` 2–4
   - `InpSL_ATR` 0.6–1.4
   - `InpTP_ATR` 0.5–1.4
   - `A1_MoveSpreadMult` 1.5–4
   - `A3_Z` 1.8–3.0
   - `InpMaxSpreadATRFrac` 0.08–0.16
3. **Out-of-sample test** on months 5–6 with the parameters frozen.
   - **Pass:** profit factor ≥ 1.25, ≥ 300 trades, equity drawdown ≤ 10 %, and net profit ≥ 50 % of the in-sample rate.
   - **If it fails, do not go live.**
4. **Demo forward test** for 4 weeks on the same VPS. Compare average slippage and fill quality with the tester. If the demo's profit factor is below 1.15, stop.
5. **Go live at 0.10 % risk** for 4 weeks, then scale up to 0.25 %. Do not exceed 0.5 %.

## 7. Known risks

- **Slippage on news spikes** is not fully covered by the news filter. The filter uses the MT5 calendar, which does not run in the tester.
- **Over-fitting:** 40+ inputs make it easy to curve-fit. Optimise at most 6–7 inputs at a time and always check out-of-sample.
- **Broker policy:** Exness permits EAs and scalping, but abusive latency-arbitrage patterns can lead to account review. This EA does not use latency arbitrage.
- **Weight drift:** if a run of losses distorts the weights, delete the `SwarmHFT_<symbol>_<magic>_w*` GlobalVariables (press F3 in MT5) to reset them.
