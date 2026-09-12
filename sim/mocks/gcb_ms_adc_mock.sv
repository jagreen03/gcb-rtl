// =============================================================================
// gcb_ms_adc_mock.sv
// Behavioral mock of the GCB-MS-ADC-V1 silicon contract.
// =============================================================================
// Reference implementation of `gcb-spec/gcb_ms_adc_v1_contract.md`. Exists so
// digital RTL can be built and verified against the custom mixed-signal
// GCB-MS-ADC-V1 part's digital interface TODAY, in parallel with whatever
// physical (analog/silicon) work eventually implements the real part — the
// "REST API contract" model: this mock IS the contract's executable form.
//
// No analog behavior of any kind is modeled (there is no analog anything to
// model - no real silicon exists). This module only implements the contract
// document's §2 pinout and §3 timing rules, exactly, and returns a fixed,
// parameterized dummy value on every successful conversion.
//
// PRELIMINARY: `CONV_LATENCY_CYCLES`'s default (16) is the same
// ESTIMATE/ASSUMPTION placeholder the contract document itself flags, not a
// measured or simulated physical timing figure. Update this parameter (and
// the contract document's own §3 rule 2) together if a real implementation's
// timing differs - a digital consumer built against this mock should only
// need to re-run its own testbench against the new value, not be rearchitected.
//
// Conformance note (contract §5): this module implements §2/§3 exactly, so a
// consumer built against it is, by construction, built against the contract.
// It deliberately does NOT implement a fault-injection path - conv_fault is
// tied low in every conversion this mock ever produces (see the port comment
// below). A consumer that needs to exercise its own conv_fault handling must
// either wrap/override this mock (e.g. a bind-based fault-injecting variant)
// or substitute a different mock for that specific test - not provided here.
// =============================================================================

module gcb_ms_adc_mock #(
    parameter int          CONV_LATENCY_CYCLES = 16,   // contract §3 rule 2 (ESTIMATE/ASSUMPTION placeholder)
    parameter logic [11:0] DUMMY_DATA          = 12'hA5A  // returned on every successful conversion
) (
    input  logic        sys_clk,
    input  logic        rst_n,
    input  logic        conv_start,

    output logic [11:0] data_out,
    output logic        data_valid,
    output logic        conv_fault          // always 0 in this mock - see header note
);

    // cnt counts down from CONV_LATENCY_CYCLES-1 to 0 - that range needs
    // clog2(CONV_LATENCY_CYCLES) bits, floored to 1 so CONV_LATENCY_CYCLES=1
    // (cnt only ever holds 0) doesn't produce a zero-width localparam.
    localparam int CNTW = (CONV_LATENCY_CYCLES <= 1) ? 1 : $clog2(CONV_LATENCY_CYCLES);

    typedef enum logic { M_IDLE, M_COUNTING } mock_state_t;
    mock_state_t        state;
    logic [CNTW-1:0]    cnt;

    // Timing derivation (contract §3 rule 1), stated explicitly so the
    // off-by-one is checkable, not asserted on faith: label the edge that
    // samples conv_start high as edge E=0. Loading cnt with
    // CONV_LATENCY_CYCLES-1 at edge 0 (visible going into edge 1), then
    // decrementing once per edge while in M_COUNTING, makes cnt read 0
    // GOING INTO edge CONV_LATENCY_CYCLES (i.e. cnt_after(e) = N-1-e for
    // e=0..N-1, which is 0 exactly when e=N-1, observed by the M_COUNTING
    // branch AT edge N). That edge's own action (data_valid<=1, etc.)
    // commits and becomes visible immediately after edge N - exactly
    // CONV_LATENCY_CYCLES=N edges after edge 0, matching the contract text
    // ("N edges after the sampling edge, data_valid asserts") exactly, not
    // N-1 or N+1. Verified by direct cycle-by-cycle trace during drafting,
    // not merely written down without checking.
    //
    // contract §3 rule 3: a conv_start sampled while COUNTING (i.e. any
    // cycle strictly between the triggering conv_start and the resulting
    // data_valid) is ignored - modeled simply by never sampling conv_start
    // at all outside M_IDLE; the FSM structure itself is the enforcement,
    // not a separate check.
    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            // contract §3 rule 4: rst_n abandons any in-flight conversion;
            // no data_valid/conv_fault for the abandoned attempt.
            state      <= M_IDLE;
            cnt        <= '0;
            data_out   <= 12'h000;
            data_valid <= 1'b0;
            conv_fault <= 1'b0;
        end else begin
            data_valid <= 1'b0;               // one-cycle strobe, default low
            conv_fault <= 1'b0;               // tied low every cycle in this mock (header note)

            case (state)
                M_IDLE: begin
                    if (conv_start) begin
                        cnt   <= CNTW'(CONV_LATENCY_CYCLES - 1);
                        state <= M_COUNTING;
                    end
                    // contract §3 rule 3: conv_start while M_COUNTING is
                    // simply never observed by this branch - no explicit
                    // "ignore" logic needed.
                end

                M_COUNTING: begin
                    if (cnt == '0) begin
                        data_out   <= DUMMY_DATA;
                        data_valid <= 1'b1;
                        state      <= M_IDLE;
                        // contract §3 rule 5: a conv_start arriving on this
                        // exact cycle is NOT sampled here (this branch only
                        // ever looks at `cnt`) - it is naturally picked up
                        // next cycle by M_IDLE, which by then has already
                        // returned, satisfying "conv_start on the data_valid
                        // cycle begins a new conversion normally" without
                        // needing same-cycle restart logic.
                    end else begin
                        cnt <= cnt - 1'b1;
                    end
                end

                default: state <= M_IDLE;
            endcase
        end
    end

    initial begin : g_assert
        if (CONV_LATENCY_CYCLES < 1)
            $fatal(1, "gcb_ms_adc_mock: CONV_LATENCY_CYCLES must be >= 1 (0 is not a meaningful 'N edges after start' latency)");
    end

`ifdef SIMULATION
    initial
        $display("[gcb_ms_adc_mock] GCB-MS-ADC-V1 behavioral mock | CONV_LATENCY_CYCLES=%0d DUMMY_DATA=%0h",
                 CONV_LATENCY_CYCLES, DUMMY_DATA);
`endif

endmodule
