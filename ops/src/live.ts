/**
 * Opens Bell Guard's demo position on the live Bell market (the one Bell's keeper feeds with real Chainlink prints
 * of Coinbase tokenized stocks), so the loop also runs on real price moves, not only in the sandbox.
 *
 * The position is a CrashLab borrower account: TSLA, MSTR and NVDA collateral, borrowed to Bell's limit, with a
 * tUSD reserve the guard may use. The trigger sits just under its current pessimistic health factor, so ordinary
 * falling prints (not only crashes) make the guard act, and every falling print of those stocks is a measured loop.
 *
 *   DEPLOYER_KEY=0x… npx tsx src/live.ts
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFunctionData, parseEventLogs, type Address } from "viem";
import { confirm, deployment as d, guardAbi, labAbi, marketAbi, pub, root, tokenAbi, wallet } from "./lib.js";

const w = wallet();
const RESERVE = 3_000n * 10n ** 6n;
const COLLATERAL: [Address, bigint][] = [
  [d.tsla, 20n * 10n ** 8n],
  [d.mstr, 60n * 10n ** 8n],
  [d.nvda, 40n * 10n ** 8n],
];

async function lab(functionName: any, args: readonly unknown[]) {
  const hash = await w.writeContract({ address: d.crashLab, abi: labAbi, functionName, args } as any);
  return confirm(hash);
}

const act = (b: Address, target: Address, data: `0x${string}`) => lab("act", [b, target, data]);

async function main() {
  if (d.liveBorrower) throw new Error(`live borrower already exists: ${d.liveBorrower}`);
  const created = await lab("newBorrower", []);
  const b = parseEventLogs({ abi: labAbi, logs: created.logs, eventName: "BorrowerCreated" })[0].args.borrower;
  console.log("borrower", b);

  for (const [token, units] of COLLATERAL) {
    await lab("mint", [token, b, units]);
    await act(b, token, encodeFunctionData({ abi: tokenAbi, functionName: "approve", args: [d.liveMarket, units] }));
    await act(b, d.liveMarket, encodeFunctionData({ abi: marketAbi, functionName: "depositCollateral", args: [token, units] }));
  }
  const power = await pub.readContract({ address: d.liveMarket, abi: marketAbi, functionName: "borrowPowerOf", args: [b] });
  await act(b, d.liveMarket, encodeFunctionData({ abi: marketAbi, functionName: "borrow", args: [power] }));

  await lab("mint", [d.usd, b, RESERVE]);
  await act(b, d.usd, encodeFunctionData({ abi: tokenAbi, functionName: "approve", args: [d.guard, RESERVE] }));
  const pessimistic = await pub.readContract({
    address: d.guard,
    abi: guardAbi,
    functionName: "pessimisticHealthOf",
    args: [d.liveMarket, b],
  });
  // Act on any meaningful fall: trigger 0.01 under today's pessimistic health, refill to 0.03 above it.
  const trigger = (pessimistic / 10n ** 16n - 1n) * 10n ** 16n;
  const target = trigger + 4n * 10n ** 16n;
  await act(
    b,
    d.guard,
    encodeFunctionData({ abi: guardAbi, functionName: "protect", args: [d.liveMarket, trigger, target, RESERVE] }),
  );

  const hf = await pub.readContract({ address: d.liveMarket, abi: marketAbi, functionName: "healthFactorOf", args: [b] });
  console.log(`debt $${Number(power) / 1e6}, health ${Number(hf) / 1e18}, pessimistic ${Number(pessimistic) / 1e18}`);
  console.log(`protected: trigger ${Number(trigger) / 1e18}, target ${Number(target) / 1e18}, budget $${Number(RESERVE) / 1e6}`);

  const file = resolve(root, "contracts/deployments/84532.json");
  const json = JSON.parse(readFileSync(file, "utf8"));
  json.liveBorrower = b;
  writeFileSync(file, JSON.stringify(json, null, 2) + "\n");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
