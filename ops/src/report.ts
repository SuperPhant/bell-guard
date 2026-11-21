/**
 * Full-loop latency report: every BellGuard callback since deployment, from the Base block holding the falling print
 * (the Observed log Reactive picked up) to the Base block in which the guard ran.
 *
 * Both ends are read from Base's own clock, the BaseTime predeploy (millisecond block timestamps, 200 ms blocks):
 * the origin with an eth_call at the origin block, the callback from the `handledAtMs` the guard logs itself.
 * Reactive's Lasna block timestamps run on a different clock (seconds, about 1.4 s behind Base when measured), so
 * the per-leg split is reported in blocks, not milliseconds.
 *
 * If ops/results/lasna-logs.json exists (BellGuardReactive's logs fetched from Lasna; see README), each loop is
 * matched with its Reactive transaction.
 *
 *   npx tsx src/report.ts
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { decodeEventLog, parseAbi, type Hash } from "viem";
import { blockMs, deployment as d, guardAbi, lasnaDeployment, logsBetween, logsPub, pub, root } from "./lib.js";

const printHandled = guardAbi.find((x) => x.type === "event" && x.name === "PrintHandled")! as any;
const guarded = guardAbi.find((x) => x.type === "event" && x.name === "Guarded")! as any;
const reactiveAbi = parseAbi([
  "event FallingPrint(address indexed market, address indexed token, uint80 roundId, int256 prevAnswer, int256 answer, uint256 dropBps, uint256 originBlock)",
  "event SweepContinued(address indexed market, address indexed token, uint80 roundId, uint256 nextIndex)",
]);

const label = (a: string) =>
  ({
    [d.sandboxMarket.toLowerCase()]: "sandbox",
    [d.liveMarket.toLowerCase()]: "live Bell",
    [d.tsla.toLowerCase()]: "TSLA",
    [d.mstr.toLowerCase()]: "MSTR",
    [d.nvda.toLowerCase()]: "NVDA",
  })[a.toLowerCase()] ?? a;

type Loop = {
  market: string;
  stock: string;
  roundId: string;
  fallPct: number;
  origin: { block: number; atMs: number };
  reactive: { block: number; tx?: Hash };
  callback: { block: number; atMs: number; tx: Hash };
  loopMs: number;
  loopBlocks: number;
  checked: number;
  rescued: number;
  repaidUsd: number;
};

function lasnaTxs(): Map<string, Hash> {
  const file = resolve(root, "ops/results/lasna-logs.json");
  const out = new Map<string, Hash>();
  if (!existsSync(file)) return out;
  for (const l of JSON.parse(readFileSync(file, "utf8")) as any[]) {
    try {
      const ev = decodeEventLog({ abi: reactiveAbi, data: l.data, topics: l.topics }) as any;
      const key = `${ev.args.market.toLowerCase()}:${ev.args.token.toLowerCase()}:${ev.args.roundId}:${BigInt(l.blockNumber)}`;
      out.set(key, l.transactionHash);
    } catch {}
  }
  return out;
}

const pct = (xs: number[], p: number) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))];
};

async function main() {
  const latest = await pub.getBlockNumber();
  const from = BigInt(d.startBlock);
  const handled = await logsBetween(
    (a, b) => logsPub.getLogs({ address: d.guard, event: printHandled, fromBlock: a, toBlock: b }),
    from,
    latest,
  );
  const rescues = await logsBetween(
    (a, b) => logsPub.getLogs({ address: d.guard, event: guarded, fromBlock: a, toBlock: b }),
    from,
    latest,
  );
  const lasna = lasnaTxs();

  const loops: Loop[] = [];
  for (const l of handled as any[]) {
    const a = l.args;
    const originMs = await blockMs(a.originBlock);
    const repaid = (rescues as any[])
      .filter((r) => r.transactionHash === l.transactionHash)
      .reduce((s, r) => s + r.args.repaid, 0n);
    loops.push({
      market: label(a.market),
      stock: label(a.token),
      roundId: a.roundId.toString(),
      fallPct: Number(((a.prevAnswer - a.answer) * 1_000_000n) / a.prevAnswer) / 10_000,
      origin: { block: Number(a.originBlock), atMs: Number(originMs) },
      reactive: {
        block: Number(a.reactiveBlock),
        tx: lasna.get(`${a.market.toLowerCase()}:${a.token.toLowerCase()}:${a.roundId}:${a.reactiveBlock}`),
      },
      callback: { block: Number(l.blockNumber), atMs: Number(a.handledAtMs), tx: l.transactionHash },
      loopMs: Number(a.handledAtMs - originMs),
      loopBlocks: Number(l.blockNumber - a.originBlock),
      checked: Number(a.checked),
      rescued: Number(a.rescued),
      repaidUsd: Number(repaid) / 1e6,
    });
  }

  const ms = loops.map((x) => x.loopMs);
  const stats = (xs: number[]) =>
    xs.length
      ? { loops: xs.length, minMs: Math.min(...xs), medianMs: pct(xs, 50), p90Ms: pct(xs, 90), maxMs: Math.max(...xs) }
      : { loops: 0 };
  const summary = {
    generatedAt: new Date().toISOString(),
    guard: d.guard,
    reactive: lasnaDeployment?.reactive ?? d.reactive,
    all: stats(ms),
    sandbox: stats(loops.filter((x) => x.market === "sandbox").map((x) => x.loopMs)),
    live: stats(loops.filter((x) => x.market === "live Bell").map((x) => x.loopMs)),
    rescues: loops.reduce((s, x) => s + x.rescued, 0),
  };

  mkdirSync(resolve(root, "docs/data"), { recursive: true });
  const loopsJson = JSON.stringify({ summary, loops }, null, 2) + "\n";
  writeFileSync(resolve(root, "ops/results/loops.json"), loopsJson);
  writeFileSync(resolve(root, "docs/data/loops.json"), loopsJson);
  const racesFile = resolve(root, "ops/results/races.json");
  writeFileSync(resolve(root, "docs/data/races.json"), existsSync(racesFile) ? readFileSync(racesFile, "utf8") : "[]\n");

  const base = "https://sepolia.basescan.org/tx/";
  const rs = "https://lasna.reactscan.net/tx/";
  const rows = loops.map(
    (x, i) =>
      `| ${i + 1} | ${x.market} | ${x.stock} | -${x.fallPct.toFixed(2)}% | ${x.origin.block} | ${
        x.reactive.tx ? `[${x.reactive.block}](${rs}${x.reactive.tx})` : x.reactive.block
      } | [${x.callback.block}](${base}${x.callback.tx}) | ${x.loopBlocks} | **${(x.loopMs / 1000).toFixed(1)} s** | ${
        x.rescued ? `$${x.repaidUsd.toLocaleString("en-US", { maximumFractionDigits: 2 })}` : "-"
      } |`,
  );
  const s = summary.all as any;
  const md = [
    "# Full-loop latency",
    "",
    `Generated ${summary.generatedAt.slice(0, 16).replace("T", " ")} UTC by \`ops/src/report.ts\` from BellGuard's own events.`,
    "",
    "A loop starts in the Base Sepolia block where a Bell market records a falling print (the `Observed` log Reactive",
    "picks up) and ends in the Base Sepolia block where BellGuard runs. Both ends are read from Base's BaseTime",
    "predeploy (millisecond block timestamps, 200 ms blocks), so the figures are on one clock.",
    "",
    s.loops
      ? `**${s.loops} loops: median ${(s.medianMs / 1000).toFixed(1)} s, 90th percentile ${(s.p90Ms / 1000).toFixed(1)} s, fastest ${(s.minMs / 1000).toFixed(1)} s, slowest ${(s.maxMs / 1000).toFixed(1)} s.**`
      : "No loops yet.",
    "",
    "| # | Market | Stock | Print | Origin block | Reactive (Lasna block) | Callback block | Blocks | Loop | Repaid |",
    "|---|---|---|---|---|---|---|---|---|---|",
    ...rows,
    "",
  ].join("\n");
  writeFileSync(resolve(root, "docs/latency.md"), md);
  console.log(JSON.stringify(summary, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
