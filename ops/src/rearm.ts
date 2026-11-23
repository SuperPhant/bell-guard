/**
 * Re-arms Bell Guard's demo position on the live Bell market: moves its trigger back to just under its current
 * pessimistic health factor, as live.ts set it when the position opened. When the stocks rally, the position's health
 * rises away from a fixed trigger and ordinary falling prints stop making the guard repay (they are still measured
 * loops). The budget is reset to the borrower's approved reserve.
 *
 *   DEPLOYER_KEY=0x… npx tsx src/rearm.ts
 */
import { encodeFunctionData } from "viem";
import { confirm, deployment as d, guardAbi, labAbi, pub, tokenAbi, wallet } from "./lib.js";

const w = wallet();

async function main() {
  const b = d.liveBorrower;
  if (!b) throw new Error("no live borrower in contracts/deployments/84532.json; run live.ts first");
  const [before, pessimistic, reserve] = await Promise.all([
    pub.readContract({ address: d.guard, abi: guardAbi, functionName: "protectionOf", args: [d.liveMarket, b] }),
    pub.readContract({ address: d.guard, abi: guardAbi, functionName: "pessimisticHealthOf", args: [d.liveMarket, b] }),
    pub.readContract({ address: d.usd, abi: tokenAbi, functionName: "allowance", args: [b, d.guard] }),
  ]);
  // Same rule as live.ts: trigger 0.01 under today's pessimistic health, refill to 0.03 above it.
  const trigger = (pessimistic / 10n ** 16n - 1n) * 10n ** 16n;
  const target = trigger + 4n * 10n ** 16n;
  const budget = reserve as bigint;
  console.log(`pessimistic health ${Number(pessimistic) / 1e18}`);
  console.log(`before: trigger ${Number(before[0]) / 1e18}, target ${Number(before[1]) / 1e18}, budget $${Number(before[2]) / 1e6}, spent $${Number(before[3]) / 1e6}`);
  const hash = await w.writeContract({
    address: d.crashLab,
    abi: labAbi,
    functionName: "act",
    args: [b, d.guard, encodeFunctionData({ abi: guardAbi, functionName: "protect", args: [d.liveMarket, trigger, target, budget] })],
  } as any);
  await confirm(hash);
  const after = await pub.readContract({ address: d.guard, abi: guardAbi, functionName: "protectionOf", args: [d.liveMarket, b] });
  console.log(`after:  trigger ${Number(after[0]) / 1e18}, target ${Number(after[1]) / 1e18}, budget $${Number(after[2]) / 1e6}, spent $${Number(after[3]) / 1e6}`);
  console.log(`tx https://sepolia.basescan.org/tx/${hash}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
