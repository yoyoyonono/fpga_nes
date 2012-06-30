/***************************************************************************************************
** fpga_nes/hw/src/cpu/apu/apu_pulse.v
*
*  Copyright (c) 2012, Brian Bennett
*  All rights reserved.
*
*  Redistribution and use in source and binary forms, with or without modification, are permitted
*  provided that the following conditions are met:
*
*  1. Redistributions of source code must retain the above copyright notice, this list of conditions
*     and the following disclaimer.
*  2. Redistributions in binary form must reproduce the above copyright notice, this list of
*     conditions and the following disclaimer in the documentation and/or other materials provided
*     with the distribution.
*
*  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
*  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
*  FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
*  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
*  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
*  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
*  WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*
*  APU noise channel.
***************************************************************************************************/

module apu_pulse
(
  input  wire       clk_in,              // system clock signal
  input  wire       rst_in,              // reset signal
  input  wire       en_in,               // enable (via $4015)
  input  wire       cpu_cycle_pulse_in,  // 1 clk pulse on every cpu cycle
  input  wire       lc_pulse_in,         // 1 clk pulse for every length counter decrement
  input  wire       eg_pulse_in,         // 1 clk pulse for every env gen update
  input  wire [1:0] a_in,                // control register addr (i.e. $400C - $400F)
  input  wire [7:0] d_in,                // control register write value
  input  wire       wr_in,               // enable control register write
  output wire [3:0] pulse_out,           // pulse channel output
  output wire       active_out           // pulse channel active (length counter > 0)
);

//
// Envelope
//
wire       envelope_generator_wr;
wire       envelope_generator_restart;
wire [3:0] envelope_generator_out;

apu_envelope_generator envelope_generator(
  .clk_in(clk_in),
  .rst_in(rst_in),
  .eg_pulse_in(eg_pulse_in),
  .env_in(d_in[5:0]),
  .env_wr_in(envelope_generator_wr),
  .env_restart(envelope_generator_restart),
  .env_out(envelope_generator_out)
);

assign envelope_generator_wr      = wr_in && (a_in == 2'b00);
assign envelope_generator_restart = wr_in && (a_in == 2'b11);

//
// Timer
//
reg  [10:0] q_timer_period, d_timer_period;

reg  [11:0] timer_period;
reg         timer_period_wr;
wire        timer_pulse;

always @(posedge clk_in)
  begin
    if (rst_in)
      begin
        q_timer_period <= 11'h000;
      end
    else
      begin
        q_timer_period <= d_timer_period;
      end
  end

apu_div #(.PERIOD_BITS(12)) timer(
  .clk_in(clk_in),
  .rst_in(rst_in),
  .pulse_in(cpu_cycle_pulse_in),
  .set_period_in(timer_period_wr),
  .period_in(timer_period),
  .pulse_out(timer_pulse)
);

//
// Sequencer
//
wire [3:0] sequencer_out;

reg  [1:0] q_duty;
wire [1:0] d_duty;

reg  [7:0] q_seq_12_5;
wire [7:0] d_seq_12_5;
reg  [7:0] q_seq_25;
wire [7:0] d_seq_25;
reg  [7:0] q_seq_50;
wire [7:0] d_seq_50;

wire       seq_bit;

always @(posedge clk_in)
  begin
    if (rst_in)
      begin
        q_duty     <= 2'h0;
        q_seq_12_5 <= 8'h40;
        q_seq_25   <= 8'h60;
        q_seq_50   <= 8'h78;
      end
    else
      begin
        q_duty     <= d_duty;
        q_seq_12_5 <= d_seq_12_5;
        q_seq_25   <= d_seq_25;
        q_seq_50   <= d_seq_50;
      end
  end

assign d_duty        = (wr_in && (a_in == 2'b00)) ? d_in[7:6] : q_duty;

assign d_seq_12_5    = (timer_pulse) ? { q_seq_12_5[0], q_seq_12_5[7:1] } : q_seq_12_5;
assign d_seq_25      = (timer_pulse) ? { q_seq_25[0],   q_seq_25[7:1] }   : q_seq_25;
assign d_seq_50      = (timer_pulse) ? { q_seq_50[0],   q_seq_50[7:1] }   : q_seq_50;

assign seq_bit       = (q_duty == 2'h0) ? q_seq_12_5[0] :
                       (q_duty == 2'h1) ? q_seq_25[0]   :
                       (q_duty == 2'h2) ? q_seq_50[0]   : ~q_seq_25[0];

assign sequencer_out = (seq_bit) ? envelope_generator_out : 4'h0;

//
// Sweep
//
reg        q_sweep_reload;
wire       d_sweep_reload;
reg  [7:0] q_sweep_reg;
wire [7:0] d_sweep_reg;

always @(posedge clk_in)
  begin
    if (rst_in)
      begin
        q_sweep_reg    <= 8'h00;
        q_sweep_reload <= 1'b0;
      end
    else
      begin
        q_sweep_reg    <= d_sweep_reg;
        q_sweep_reload <= d_sweep_reload;
      end
  end

assign d_sweep_reg    = (wr_in && (a_in == 2'b01)) ? d_in : q_sweep_reg;
assign d_sweep_reload = (wr_in && (a_in == 2'b01)) ? 1'b1 : 
                        (lc_pulse_in)              ? 1'b0 : q_sweep_reload;

wire sweep_divider_period_wr;
wire sweep_divider_pulse;

apu_div #(.PERIOD_BITS(3)) sweep_divider(
  .clk_in(clk_in),
  .rst_in(rst_in),
  .pulse_in(lc_pulse_in),
  .set_period_in(sweep_divider_period_wr),
  .period_in(q_sweep_reg[6:4]),
  .pulse_out(sweep_divider_pulse)
);

assign sweep_divider_period_wr = lc_pulse_in & q_sweep_reload;

always @*
  begin
    d_timer_period  = q_timer_period;
    timer_period_wr = 1'b0;

    if (wr_in && (a_in == 2'b10))
      begin
        d_timer_period  = { q_timer_period[10:8], d_in };
        timer_period_wr = 1'b1;
      end
    else if (wr_in && (a_in == 2'b11))
      begin
        d_timer_period  = { d_in[2:0], q_timer_period[7:0] };
        timer_period_wr = 1'b1;
      end
    else if (q_sweep_reg[7] && sweep_divider_pulse && (q_sweep_reg[2:0] != 3'h0))
      begin
        if (!q_sweep_reg[3])
          begin
            d_timer_period  = q_timer_period + (q_timer_period >> q_sweep_reg[2:0]);
            timer_period_wr = 1'b1;
          end
        else
          begin
            d_timer_period  = q_timer_period - (q_timer_period >> q_sweep_reg[2:0]);
            timer_period_wr = 1'b1;
          end
      end

    timer_period = { d_timer_period, 1'b0 };
  end

//
// Length Counter
//
reg  q_length_counter_halt;
wire d_length_counter_halt;

always @(posedge clk_in)
  begin
    if (rst_in)
      begin
        q_length_counter_halt <= 1'b0;
      end
    else
      begin
        q_length_counter_halt <= d_length_counter_halt;
      end
  end

assign d_length_counter_halt = (wr_in && (a_in == 2'b00)) ? d_in[5] : q_length_counter_halt;

wire length_counter_wr;
wire length_counter_en;

apu_length_counter length_counter(
  .clk_in(clk_in),
  .rst_in(rst_in),
  .en_in(en_in),
  .halt_in(q_length_counter_halt),
  .length_pulse_in(lc_pulse_in),
  .length_in(d_in[7:3]),
  .length_wr_in(length_counter_wr),
  .en_out(length_counter_en)
);

assign length_counter_wr = wr_in && (a_in == 2'b11);

assign pulse_out  = (length_counter_en) ? sequencer_out : 4'h0;
assign active_out = length_counter_en;

endmodule

