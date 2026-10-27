// runScript: reads the flow's env and its own, and hands values back through `output`.
output.plan = PLAN;
output.greeting = GREETING + ', ' + PLAN.toLowerCase();
console.log('picked ' + output.plan);
