# Targets for the Rust core (core/). The Makefile includes every mk/*.mk, so add targets here
# without editing it. Document each new target with a "#   make <target>  <what it does>" line,
# which make help prints.
#
#   make bench-core       core latency budgets: the Rust engine bench, then the CoreBridge bench
#                         (engine, calculator and file index through the FFI)
#   make sim              the ranking simulator: typed and zero-query tables for 60 held-out users

.PHONY: bench-core sim

# Both benches exit non-zero when a budget is blown. They run from the terminal at the
# user-interactive QoS class; `make bench` measures inside the app bundle. BENCH_ONLY=engine, calc
# or files runs one section of the CoreBridge bench.
bench-core: core
	@$(CARGO) bench --locked -p slick-engine --bench engine
	@$(SWIFTPM) $(ROOT)/Packages/CoreBridge run -c release corebridge-bench

sim:
	@$(CARGO) run --locked --release -p slick-predict --example sim -- eval
