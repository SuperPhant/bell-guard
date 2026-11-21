/**
 * One sandbox race between Bell Guard and the confirming print, on Base Sepolia + Reactive Lasna.
 *
 *   1. Reset the sandbox TSLA price to the start price (two prints, so both of Bell's prints agree).
 *   2. Open two identical borrowers at Bell's borrowing limit.
 *   3. A slide: two prints `--slide` lower (the guard is called back for the first one; nobody is protected yet).
 *   4. Arm the guard on one borrower: trigger 1.25, target 1.40.
 *   5. The warning: one print `--drop` lower. Bell cannot liquidate on it; BellGuardReactive wakes the guard.
 *   6. `--delay` ms after the warning is sent, the confirming print, immediately followed by liquidation attempts on
 *      both borrowers, in the same transaction. Both are signed up front, so short delays really are short.
 *
 * Every time comes from Base's BaseTime predeploy (200 ms blocks), read from the contracts' own events.
 *
 *   DEPLOYER_KEY=0x… npx tsx src/race.ts --delay 3000 [--drop 0.15] [--slide 0.16] [--note text]
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { decodeEventLog, encodeFunctionData, parseEventLogs, type Hash, type Hex } from "viem";
import { confirm, deployment as d, guardAbi, labAbi, logsPub, marketAbi, pub, root, sleep, wallet } from "./lib.js";

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const delayMs = Number(arg("delay", "3000"));
const drop = Number(arg("drop", "0.15"));
const slide = Number(arg("slide", "0.16"));
const note = arg("note", "");
const UNITS = 100n * 10n ** 8n; // 100 tTSLAc each
const RESERVE = 10_000n * 10n ** 6n; // $10,000 of tUSD in each wallet
const TRIGGER = 125n * 10n ** 16n;
const TARGET = 140n * 10n ** 16n;

const w = wallet();
const start = BigInt(d.sandboxStartPrice);
const scale = (p: bigint, f: number) => (p * BigInt(Math.round((1 - f) * 1_000_000))) / 1_000_000n;

async function tx(functionName: any, args: readonly unknown[]) {
  const hash = await w.writeContract({ address: d.crashLab, abi: labAbi, functionName, args } as any);
  return confirm(hash);
}

async function print(answer: bigint) {
  const r = await tx("print", [d.tsla, answer]);
  const ev = parseEventLogs({ abi: labAbi, logs: r.logs, eventName: "Printed" })[0];
  return { receipt: r, roundId: ev.args.roundId, atMs: ev.args.atMs };
}

type Handled = { tx: Hash; block: bigint; handledAtMs: bigint; originBlock: bigint; rescued: bigint; logs: any[] };

/** Waits for the guard's PrintHandled for `roundId` on the sandbox market. */
async function handled(roundId: bigint, fromBlock: bigint, timeoutMs = 90_000): Promise<Handled | undefined> {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    const logs = await logsPub.getLogs({
      address: d.guard,
      event: guardAbi.find((x) => x.type === "event" && x.name === "PrintHandled") as any,
      args: { market: d.sandboxMarket },
      fromBlock,
    });
    for (const l of logs as any[]) {
      if (l.args.roundId === roundId) {
        const receipt = await pub.getTransactionReceipt({ hash: l.transactionHash });
        return {
          tx: l.transactionHash,
          block: l.blockNumber,
          handledAtMs: l.args.handledAtMs,
          originBlock: l.args.originBlock,
          rescued: l.args.rescued,
          logs: receipt.logs,
        };
      }
    }
    await sleep(250);
  }
  return undefined;
}

async function main() {
  const t0 = await pub.getBlockNumber();

  // 1. Baseline: both of Bell's prints at the start price.
  for (let i = 0; i < 2; i++) {
    const [, , last, prev] = await pub.readContract({
      address: d.sandboxMarket,
      abi: marketAbi,
      functionName: "observationOf",
      args: [d.tsla],
    });
    if (last === start && prev === start) break;
    const p = await print(start);
    if (last > start) await handled(p.roundId, p.receipt.blockNumber); // a fall: let its callback land first
  }

  // 2. Two identical borrowers.
  const opened = await tx("openPair", [d.tsla, UNITS, RESERVE]);
  const pair = parseEventLogs({ abi: labAbi, logs: opened.logs, eventName: "PairOpened" })[0].args;
  console.log(`pair ${pair.pairId}: guarded ${pair.guarded}, unguarded ${pair.unguarded}, debt $${Number(pair.debt) / 1e6} each`);

  // 3. The slide.
  const p1 = scale(start, slide);
  const s1 = await print(p1);
  const slideLoop = await handled(s1.roundId, s1.receipt.blockNumber);
  await print(p1);

  // 4. Arm.
  await tx("arm", [pair.pairId, TRIGGER, TARGET, RESERVE]);
  const hfBefore = await pub.readContract({ address: d.sandboxMarket, abi: marketAbi, functionName: "healthFactorOf", args: [pair.guarded] });

  // 5. The warning print and 6. the confirming print are signed up front (consecutive nonces), so the gap between
  //    them is only the requested delay plus inclusion, not receipt polling.
  const p2 = scale(p1, drop);
  const warnRound = (await pub.readContract({ address: d.crashLab, abi: labAbi, functionName: "round" })) + 1n;
  const nonce = await pub.getTransactionCount({ address: w.account.address, blockTag: "pending" });
  const fees = await pub.estimateFeesPerGas();
  const sign = async (data: Hex, n: number, gas: bigint) =>
    w.signTransaction(
      await w.prepareTransactionRequest({
        to: d.crashLab,
        data,
        nonce: n,
        gas,
        maxFeePerGas: fees.maxFeePerGas * 2n,
        maxPriorityFeePerGas: fees.maxPriorityFeePerGas * 2n,
      } as any) as any,
    );
  const warnRaw = await sign(encodeFunctionData({ abi: labAbi, functionName: "print", args: [d.tsla, p2] }), nonce, 500_000n);
  const confRaw = await sign(
    encodeFunctionData({ abi: labAbi, functionName: "confirmAndLiquidate", args: [pair.pairId, p2] }),
    nonce + 1,
    2_500_000n,
  );
  const fromBlock = await pub.getBlockNumber();
  const sentAt = Date.now();
  const warnHash = await pub.sendRawTransaction({ serializedTransaction: warnRaw });
  const watching = handled(warnRound, fromBlock);
  const wait = delayMs - (Date.now() - sentAt);
  if (wait > 0) await sleep(wait);
  const confHash = await pub.sendRawTransaction({ serializedTransaction: confRaw });
  const warnReceipt = await confirm(warnHash);
  const conf = await confirm(confHash);
  const warn = {
    receipt: warnReceipt,
    roundId: warnRound,
    atMs: parseEventLogs({ abi: labAbi, logs: warnReceipt.logs, eventName: "Printed" })[0].args.atMs,
  };
  const confPrint = parseEventLogs({ abi: labAbi, logs: conf.logs, eventName: "Printed" })[0].args;
  const attempts = parseEventLogs({ abi: labAbi, logs: conf.logs, eventName: "LiquidationAttempt" }).map((e) => e.args);
  const guardedTry = attempts.find((a) => a.account.toLowerCase() === pair.guarded.toLowerCase())!;
  const unguardedTry = attempts.find((a) => a.account.toLowerCase() === pair.unguarded.toLowerCase())!;

  const loop = await watching;
  let repaid = 0n;
  if (loop) {
    for (const l of loop.logs) {
      if (l.address.toLowerCase() !== d.guard.toLowerCase()) continue;
      try {
        const ev = decodeEventLog({ abi: guardAbi, data: l.data, topics: l.topics }) as any;
        if (ev.eventName === "Guarded" && ev.args.account.toLowerCase() === pair.guarded.toLowerCase()) repaid = ev.args.repaid;
      } catch {}
    }
  }

  await tx("disarm", [pair.pairId]);

  const result = {
    at: new Date().toISOString(),
    note,
    pairId: Number(pair.pairId),
    prices: { start: Number(start) / 1e8, slide: Number(p1) / 1e8, warning: Number(p2) / 1e8 },
    guardedHealthBeforeWarning: Number(hfBefore) / 1e18,
    requestedDelayMs: delayMs,
    warning: { tx: warn.receipt.transactionHash, block: Number(warn.receipt.blockNumber), atMs: Number(warn.atMs) },
    confirming: { tx: conf.transactionHash, block: Number(conf.blockNumber), atMs: Number(confPrint.atMs) },
    confirmAfterWarningMs: Number(confPrint.atMs - warn.atMs),
    guard: loop
      ? {
          tx: loop.tx,
          block: Number(loop.block),
          atMs: Number(loop.handledAtMs),
          loopMs: Number(loop.handledAtMs - warn.atMs),
          loopBlocks: Number(loop.block - warn.receipt.blockNumber),
          repaid: Number(repaid) / 1e6,
          beforeConfirmingPrint: loop.block < conf.blockNumber,
        }
      : null,
    slideLoopMs: slideLoop ? Number(slideLoop.handledAtMs - s1.atMs) : null,
    guardedLiquidated: guardedTry.liquidated,
    unguardedLiquidated: unguardedTry.liquidated,
    unguardedSeized: Number(unguardedTry.seized) / 1e8,
    unguardedPenaltyUsd: unguardedTry.liquidated
      ? Number(unguardedTry.seized * p2) / 1e16 - Number(unguardedTry.repaid) / 1e6
      : 0,
  };
  const file = resolve(root, "ops/results/races.json");
  const all = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : [];
  all.push(result);
  writeFileSync(file, JSON.stringify(all, null, 2) + "\n");
  console.log(JSON.stringify(result, null, 2));
  console.log(`blocks scanned from ${t0}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
