# Full-loop latency

Generated 2026-11-22 23:22 UTC by `ops/src/report.ts` from BellGuard's own events.

A loop starts in the Base Sepolia block where a Bell market records a falling print (the `Observed` log Reactive
picks up) and ends in the Base Sepolia block where BellGuard runs. Both ends are read from Base's BaseTime
predeploy (millisecond block timestamps, 200 ms blocks), so the figures are on one clock.

**9 loops: median 1.6 s, 90th percentile 1.8 s, fastest 1.0 s, slowest 1.8 s.**

| # | Market | Stock | Print | Origin block | Reactive (Lasna block) | Callback block | Blocks | Loop | Repaid |
|---|---|---|---|---|---|---|---|---|---|
| 1 | sandbox | TSLA | -1.99% | 61633403 | [8877998](https://lasna.reactscan.net/tx/0x2ef9a6995f3ae48e8f05d86c320e1e24e84e72fa84881a45cc2b5ba51c4df0dd) | [61633408](https://sepolia.basescan.org/tx/0xcadb898d6c88a99533b3b8ece71700df41e693cc4d7eea61847667b16c929483) | 5 | **1.0 s** | - |
| 2 | sandbox | TSLA | -16.00% | 61633887 | [8878090](https://lasna.reactscan.net/tx/0xba74c38f8c5531fceb168e24d953c0563c01a8de8e30615f298bd2057de75619) | [61633892](https://sepolia.basescan.org/tx/0xd6dfb072ab75d0f70f7faa4a249a3a22cb8c4914fc31c2d274a66bf69d2808d5) | 5 | **1.0 s** | - |
| 3 | sandbox | TSLA | -15.00% | 61633920 | [8878097](https://lasna.reactscan.net/tx/0x0959b738b3e161a686841901046422ee9749427379c7bec248ca903ff95d0414) | [61633928](https://sepolia.basescan.org/tx/0xafdd62367827bfb5fe9934deff16e0784f9af56bfd7e8ac774d2ea9707fbde89) | 8 | **1.6 s** | $4,145.51 |
| 4 | sandbox | TSLA | -16.00% | 61634241 | [8878158](https://lasna.reactscan.net/tx/0xa9135079625ca4c804ce9e5237fbf07e7fe8a96509796859fabda8e36237dba8) | [61634249](https://sepolia.basescan.org/tx/0x08da1d4cdfab171ab3877eebabad7ae100da242fa9a3268013abe73e8f35b7b1) | 8 | **1.6 s** | - |
| 5 | sandbox | TSLA | -15.00% | 61634284 | [8878166](https://lasna.reactscan.net/tx/0xb371ea040f159b6ae664c3e4ccfa13bef3cb430fd1c2f63efe3c21781305fd61) | [61634293](https://sepolia.basescan.org/tx/0x31cad3c98739f0b1b79e4ee260e95dc5dba8e002afeb3c99ee2bcffd763e79f7) | 9 | **1.8 s** | - |
| 6 | sandbox | TSLA | -16.00% | 61634389 | [8878185](https://lasna.reactscan.net/tx/0x77df287d3603dd47be9bc36059afa2ca6a509230048b7382b332330b2f358600) | [61634396](https://sepolia.basescan.org/tx/0xb0f1d09d5376adb1e1bdccf739ee6f491f308d3733dc86a20612410af16d00b1) | 7 | **1.4 s** | - |
| 7 | sandbox | TSLA | -15.00% | 61634429 | [8878192](https://lasna.reactscan.net/tx/0x1b445ddf1c7267037d9667bf3977e7bdd019f3fc4d9fc995856f747895614a1c) | [61634434](https://sepolia.basescan.org/tx/0x0fd66a176988dc684da3494558a101235d7fcd3ca1c12a9c279a5b71bb826eed) | 5 | **1.0 s** | $4,145.51 |
| 8 | sandbox | TSLA | -16.00% | 61641153 | [8879464](https://lasna.reactscan.net/tx/0x269afe0e11b4727ad749b626d392aad0922c025a7fb6b2cd4a96e3461525f7f6) | [61641162](https://sepolia.basescan.org/tx/0xbc6a568fbc9db5fe67aeedc0c6c006c5b1db0e688c3e1ec45e1aa4dd8962529c) | 9 | **1.8 s** | - |
| 9 | sandbox | TSLA | -15.00% | 61641265 | [8879485](https://lasna.reactscan.net/tx/0xc5e4d30bcafee651cd2cd88233459d8f127062ee5c6345cb5c6ea728baadb512) | [61641273](https://sepolia.basescan.org/tx/0xe1d483cb51337f342d89f7169bc03face163e9b5e8a43ab95359e3662b06d449) | 8 | **1.6 s** | $4,145.52 |
