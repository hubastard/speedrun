// Times each step and prints the medians, as compare.sh does for speedrun and Maestro.
export function timer() {
  const times: Record<string, number[]> = {};
  const start = Date.now();
  return {
    async step(name: string, fn: () => Promise<unknown>) {
      const t = Date.now();
      await fn();
      (times[name] ??= []).push(Date.now() - t);
    },
    report() {
      const median = (a: number[]) => [...a].sort((x, y) => x - y)[a.length >> 1];
      for (const [k, v] of Object.entries(times)) console.log(`BENCH ${k.padEnd(30)} median ${median(v)} ms  (${v.join(', ')})`);
      console.log(`BENCH flow ${((Date.now() - start) / 1000).toFixed(1)} s`);
    },
  };
}
