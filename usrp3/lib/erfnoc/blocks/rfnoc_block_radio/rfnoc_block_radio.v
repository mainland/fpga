//
// Copyright 2019 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: rfnoc_block_radio
//
// Description:  This is the top-level file for the RFNoC radio block.
//
// Parameters:
//
//   CHDR_W           : CHDR AXI-Stream data bus width
//   NSPC             : Number of radio samples per radio clock cycle
//   SAMP_W           : Radio sample width
//   NUM_CHANNELS     : Number of radio channels (RX/TX pairs)
//   THIS_PORTID      : CTRL port ID to which this block is connected
//   MTU              : Maximum transmission unit (i.e., maximum packet size) 
//                      in CHDR words is 2**MTU.
//   PYLD_FIFO_SIZE   : Size of FIFO for DATA path = 2**PYLD_FIFO_SIZE
//   CTRL_FIFO_SIZE   : Size of FIFO for CTRL port = 2**CTRL_FIFO_SIZE
//   PERIPH_BASE_ADDR : CTRL port peripheral window base address
//   PERIPH_ADDR_W    : CTRL port peripheral address space = 2**PERIPH_ADDR_W
//


module rfnoc_block_radio #(
  parameter CHDR_W           = 64,
  parameter NSPC             = 2,
  parameter SAMP_W           = 32,
  parameter NUM_CHANNELS     = 1,
  parameter THIS_PORTID      = 0,
  parameter MTU              = 10,
  parameter PYLD_FIFO_SIZE   = 11,
  parameter CTRL_FIFO_SIZE   = 5,
  parameter PERIPH_BASE_ADDR = 20'h80000,
  parameter PERIPH_ADDR_W    = 19
) (
  //---------------------------------------------------------------------------
  // AXIS CHDR Port
  //---------------------------------------------------------------------------

  input wire rfnoc_chdr_clk,

  // CHDR inputs from framework
  input  wire [NUM_CHANNELS*CHDR_W-1:0] s_rfnoc_chdr_tdata,
  input  wire [       NUM_CHANNELS-1:0] s_rfnoc_chdr_tlast,
  input  wire [       NUM_CHANNELS-1:0] s_rfnoc_chdr_tvalid,
  output wire [       NUM_CHANNELS-1:0] s_rfnoc_chdr_tready,

  // CHDR outputs to framework
  output wire [NUM_CHANNELS*CHDR_W-1:0] m_rfnoc_chdr_tdata,
  output wire [       NUM_CHANNELS-1:0] m_rfnoc_chdr_tlast,
  output wire [       NUM_CHANNELS-1:0] m_rfnoc_chdr_tvalid,
  input  wire [       NUM_CHANNELS-1:0] m_rfnoc_chdr_tready,

  // Backend interface
  input  wire [511:0] rfnoc_core_config,
  output wire [511:0] rfnoc_core_status,


  //---------------------------------------------------------------------------
  // AXIS CTRL Port
  //---------------------------------------------------------------------------

  input wire rfnoc_ctrl_clk,

  // CTRL port requests from framework
  input  wire [31:0] s_rfnoc_ctrl_tdata,
  input  wire        s_rfnoc_ctrl_tlast,
  input  wire        s_rfnoc_ctrl_tvalid,
  output wire        s_rfnoc_ctrl_tready,

  // CTRL port requests to framework
  output wire [31:0] m_rfnoc_ctrl_tdata,
  output wire        m_rfnoc_ctrl_tlast,
  output wire        m_rfnoc_ctrl_tvalid,
  input  wire        m_rfnoc_ctrl_tready,


  //---------------------------------------------------------------------------
  // CTRL Port Peripheral Interface
  //---------------------------------------------------------------------------

  output wire        m_ctrlport_req_wr,
  output wire        m_ctrlport_req_rd,
  output wire [19:0] m_ctrlport_req_addr,
  output wire [31:0] m_ctrlport_req_data,
  output wire [ 3:0] m_ctrlport_req_byte_en,
  output wire        m_ctrlport_req_has_time,
  output wire [63:0] m_ctrlport_req_time,
  input  wire        m_ctrlport_resp_ack,
  input  wire [ 1:0] m_ctrlport_resp_status,
  input  wire [31:0] m_ctrlport_resp_data,


  //---------------------------------------------------------------------------
  // Radio Interface
  //---------------------------------------------------------------------------

  input wire radio_clk,

  // Timekeeper interface
  input wire [63:0] radio_time,

  // Radio Rx interface
  input  wire [NUM_CHANNELS*(SAMP_W*NSPC)-1:0] radio_rx_data,
  input  wire [              NUM_CHANNELS-1:0] radio_rx_stb,
  output wire [              NUM_CHANNELS-1:0] radio_rx_running,

  // Radio Tx interface
  output wire [NUM_CHANNELS*(SAMP_W*NSPC)-1:0] radio_tx_data,
  input  wire [              NUM_CHANNELS-1:0] radio_tx_stb,
  output wire [              NUM_CHANNELS-1:0] radio_tx_running
);

  `include "rfnoc_block_radio_regs.vh"
  `include "../../core/rfnoc_axis_ctrl_utils.vh"

  localparam RADIO_W = NSPC*SAMP_W;


  // Radio Tx data stream
  wire [NUM_CHANNELS*(RADIO_W)-1:0] axis_tx_tdata;
  wire [          NUM_CHANNELS-1:0] axis_tx_tlast;
  wire [          NUM_CHANNELS-1:0] axis_tx_tvalid;
  wire [          NUM_CHANNELS-1:0] axis_tx_tready;
  wire [       NUM_CHANNELS*64-1:0] axis_tx_ttimestamp;
  wire [          NUM_CHANNELS-1:0] axis_tx_thas_time;
  wire [          NUM_CHANNELS-1:0] axis_tx_teob;

  // Radio Rx data stream
  wire [NUM_CHANNELS*(RADIO_W)-1:0] axis_rx_tdata;
  wire [          NUM_CHANNELS-1:0] axis_rx_tlast;
  wire [          NUM_CHANNELS-1:0] axis_rx_tvalid;
  wire [          NUM_CHANNELS-1:0] axis_rx_tready;
  wire [       NUM_CHANNELS*64-1:0] axis_rx_ttimestamp;
  wire [          NUM_CHANNELS-1:0] axis_rx_teob;

  // Control port signals used for register access (NoC shell masters user logic)
  wire        ctrlport_reg_req_wr;
  wire        ctrlport_reg_req_rd;
  wire [19:0] ctrlport_reg_req_addr;
  wire [31:0] ctrlport_reg_req_data;
  wire [31:0] ctrlport_reg_resp_data;
  wire        ctrlport_reg_resp_ack;

  // Control port signals used for error reporting (user logic masters to NoC shell)
  wire        ctrlport_err_req_wr;
  wire [19:0] ctrlport_err_req_addr;
  wire [ 9:0] ctrlport_err_req_portid;
  wire [15:0] ctrlport_err_req_rem_epid;
  wire [ 9:0] ctrlport_err_req_rem_portid;
  wire [31:0] ctrlport_err_req_data;
  wire        ctrlport_err_resp_ack;


  //---------------------------------------------------------------------------
  // NoC Shell
  //---------------------------------------------------------------------------

  wire rfnoc_chdr_rst;
  wire radio_rst;

  noc_shell_radio #(
    .NOC_ID          ('h12AD_1000_0000_0000),
    .THIS_PORTID     (THIS_PORTID),
    .CHDR_W          (CHDR_W),
    .CTRL_FIFO_SIZE  (CTRL_FIFO_SIZE),
    .CTRLPORT_SLV_EN (1),
    .CTRLPORT_MST_EN (1),
    .NUM_DATA_I      (NUM_CHANNELS),
    .NUM_DATA_O      (NUM_CHANNELS),
    .ITEM_W          (SAMP_W),
    .NIPC            (NSPC),
    .MTU             (MTU),
    .CTXT_FIFO_SIZE  (1),
    .PYLD_FIFO_SIZE  (PYLD_FIFO_SIZE)
  ) noc_shell_radio_i (
    .rfnoc_chdr_clk            (rfnoc_chdr_clk),
    .rfnoc_chdr_rst            (rfnoc_chdr_rst),
    .rfnoc_ctrl_clk            (rfnoc_ctrl_clk),
    .rfnoc_ctrl_rst            (),
    .rfnoc_core_config         (rfnoc_core_config),
    .rfnoc_core_status         (rfnoc_core_status),
    .s_rfnoc_chdr_tdata        (s_rfnoc_chdr_tdata),
    .s_rfnoc_chdr_tlast        (s_rfnoc_chdr_tlast),
    .s_rfnoc_chdr_tvalid       (s_rfnoc_chdr_tvalid),
    .s_rfnoc_chdr_tready       (s_rfnoc_chdr_tready),
    .m_rfnoc_chdr_tdata        (m_rfnoc_chdr_tdata),
    .m_rfnoc_chdr_tlast        (m_rfnoc_chdr_tlast),
    .m_rfnoc_chdr_tvalid       (m_rfnoc_chdr_tvalid),
    .m_rfnoc_chdr_tready       (m_rfnoc_chdr_tready),
    .s_rfnoc_ctrl_tdata        (s_rfnoc_ctrl_tdata),
    .s_rfnoc_ctrl_tlast        (s_rfnoc_ctrl_tlast),
    .s_rfnoc_ctrl_tvalid       (s_rfnoc_ctrl_tvalid),
    .s_rfnoc_ctrl_tready       (s_rfnoc_ctrl_tready),
    .m_rfnoc_ctrl_tdata        (m_rfnoc_ctrl_tdata),
    .m_rfnoc_ctrl_tlast        (m_rfnoc_ctrl_tlast),
    .m_rfnoc_ctrl_tvalid       (m_rfnoc_ctrl_tvalid),
    .m_rfnoc_ctrl_tready       (m_rfnoc_ctrl_tready),
    .ctrlport_clk              (radio_clk),
    .ctrlport_rst              (radio_rst),
    .m_ctrlport_req_wr         (ctrlport_reg_req_wr),
    .m_ctrlport_req_rd         (ctrlport_reg_req_rd),
    .m_ctrlport_req_addr       (ctrlport_reg_req_addr),
    .m_ctrlport_req_data       (ctrlport_reg_req_data),
    .m_ctrlport_req_byte_en    (),
    .m_ctrlport_req_has_time   (),
    .m_ctrlport_req_time       (),
    .m_ctrlport_resp_ack       (ctrlport_reg_resp_ack),
    .m_ctrlport_resp_status    (AXIS_CTRL_STS_OKAY),
    .m_ctrlport_resp_data      (ctrlport_reg_resp_data),
    .s_ctrlport_req_wr         (ctrlport_err_req_wr),
    .s_ctrlport_req_rd         (1'b0),
    .s_ctrlport_req_addr       (ctrlport_err_req_addr),
    .s_ctrlport_req_portid     (ctrlport_err_req_portid),
    .s_ctrlport_req_rem_epid   (ctrlport_err_req_rem_epid),
    .s_ctrlport_req_rem_portid (ctrlport_err_req_rem_portid),
    .s_ctrlport_req_data       (ctrlport_err_req_data),
    .s_ctrlport_req_byte_en    (4'hF),
    .s_ctrlport_req_has_time   (1'b0),
    .s_ctrlport_req_time       (64'b0),
    .s_ctrlport_resp_ack       (ctrlport_err_resp_ack),
    .s_ctrlport_resp_status    (),
    .s_ctrlport_resp_data      (),
    .axis_data_clk             (radio_clk),
    .axis_data_rst             (radio_rst),
    .m_axis_tdata              (axis_tx_tdata),
    .m_axis_tkeep              (),                          // Radio only transmits full words
    .m_axis_tlast              (axis_tx_tlast),
    .m_axis_tvalid             (axis_tx_tvalid),
    .m_axis_tready             (axis_tx_tready),
    .m_axis_ttimestamp         (axis_tx_ttimestamp),
    .m_axis_thas_time          (axis_tx_thas_time),
    .m_axis_teov               (),
    .m_axis_teob               (axis_tx_teob),
    .s_axis_tdata              (axis_rx_tdata),
    .s_axis_tkeep              ({NUM_CHANNELS*NSPC{1'b1}}), // Radio only receives full words
    .s_axis_tlast              (axis_rx_tlast),
    .s_axis_tvalid             (axis_rx_tvalid),
    .s_axis_tready             (axis_rx_tready),
    .s_axis_ttimestamp         (axis_rx_ttimestamp),
    .s_axis_thas_time          ({NUM_CHANNELS{1'b1}}),      // Rx packet always include a timestamp
    .s_axis_teov               ({NUM_CHANNELS{1'b0}}),
    .s_axis_teob               (axis_rx_teob)
  );

  // Cross the CHDR reset to the radio_clk domain
  pulse_synchronizer #(
    .MODE ("POSEDGE")
  ) ctrl_rst_sync_i (
    .clk_a   (rfnoc_chdr_clk),
    .rst_a   (1'b0),
    .pulse_a (rfnoc_chdr_rst),
    .busy_a  (),
    .clk_b   (radio_clk),
    .pulse_b (radio_rst)
  );


  //---------------------------------------------------------------------------
  // Decode Control Port Addresses
  //---------------------------------------------------------------------------
  //
  // This block splits the NoC shell's single master control port interface 
  // into three masters, connected to the shared registers, radio cores, and 
  // the external CTRL port peripheral interface. The responses from each of 
  // these are merged into a single response and sent back to the NoC shell.
  //
  //---------------------------------------------------------------------------

  wire        ctrlport_shared_req_wr;
  wire        ctrlport_shared_req_rd;
  wire [19:0] ctrlport_shared_req_addr;
  wire [31:0] ctrlport_shared_req_data;
  wire [ 3:0] ctrlport_shared_req_byte_en;
  wire        ctrlport_shared_req_has_time;
  wire [63:0] ctrlport_shared_req_time;
  reg         ctrlport_shared_resp_ack  = 1'b0;
  reg  [31:0] ctrlport_shared_resp_data = 0;

  wire        ctrlport_core_req_wr;
  wire        ctrlport_core_req_rd;
  wire [19:0] ctrlport_core_req_addr;
  wire [31:0] ctrlport_core_req_data;
  wire [ 3:0] ctrlport_core_req_byte_en;
  wire        ctrlport_core_req_has_time;
  wire [63:0] ctrlport_core_req_time;
  wire        ctrlport_core_resp_ack;
  wire [31:0] ctrlport_core_resp_data;

  ctrlport_decoder_param #(
    .NUM_SLAVES   (3),
    .PORT0_BASE   (SHARED_BASE_ADDR),
    .PORT0_ADDR_W (SHARED_ADDR_W),
    .PORT1_BASE   (RADIO_BASE_ADDR),
    .PORT1_ADDR_W (RADIO_ADDR_W + $clog2(NUM_CHANNELS)),
    .PORT2_BASE   (PERIPH_BASE_ADDR),
    .PORT2_ADDR_W (PERIPH_ADDR_W)
  ) ctrlport_decoder_param_i (
    .ctrlport_clk            (radio_clk),
    .ctrlport_rst            (radio_rst),
    .s_ctrlport_req_wr       (ctrlport_reg_req_wr),
    .s_ctrlport_req_rd       (ctrlport_reg_req_rd),
    .s_ctrlport_req_addr     (ctrlport_reg_req_addr),
    .s_ctrlport_req_data     (ctrlport_reg_req_data),
    .s_ctrlport_req_byte_en  (4'b0),
    .s_ctrlport_req_has_time (1'b0),
    .s_ctrlport_req_time     (64'b0),
    .s_ctrlport_resp_ack     (ctrlport_reg_resp_ack),
    .s_ctrlport_resp_status  (),
    .s_ctrlport_resp_data    (ctrlport_reg_resp_data),
    .m_ctrlport_req_wr       ({m_ctrlport_req_wr,
                               ctrlport_core_req_wr,
                               ctrlport_shared_req_wr}),
    .m_ctrlport_req_rd       ({m_ctrlport_req_rd,
                               ctrlport_core_req_rd,
                               ctrlport_shared_req_rd}),
    .m_ctrlport_req_addr     ({m_ctrlport_req_addr,
                               ctrlport_core_req_addr,
                               ctrlport_shared_req_addr}),
    .m_ctrlport_req_data     ({m_ctrlport_req_data,
                               ctrlport_core_req_data,
                               ctrlport_shared_req_data}),
    .m_ctrlport_req_byte_en  ({m_ctrlport_req_byte_en,
                               ctrlport_core_req_byte_en,
                               ctrlport_shared_req_byte_en}),
    .m_ctrlport_req_has_time ({m_ctrlport_req_has_time,
                               ctrlport_core_req_has_time,
                               ctrlport_shared_req_has_time}),
    .m_ctrlport_req_time     ({m_ctrlport_req_time,
                               ctrlport_core_req_time,
                               ctrlport_shared_req_time}),
    .m_ctrlport_resp_ack     ({m_ctrlport_resp_ack,
                               ctrlport_core_resp_ack,
                               ctrlport_shared_resp_ack}),
    .m_ctrlport_resp_status  ({m_ctrlport_resp_status,
                              2'b00,
                              2'b00}),
    .m_ctrlport_resp_data    ({m_ctrlport_resp_data,
                               ctrlport_core_resp_data,
                               ctrlport_shared_resp_data
                               })
  );


  //---------------------------------------------------------------------------
  // Split Radio Control Port Interfaces
  //---------------------------------------------------------------------------

  wire [   NUM_CHANNELS-1:0] ctrlport_radios_req_wr;
  wire [   NUM_CHANNELS-1:0] ctrlport_radios_req_rd;
  wire [20*NUM_CHANNELS-1:0] ctrlport_radios_req_addr;
  wire [32*NUM_CHANNELS-1:0] ctrlport_radios_req_data;
  wire [   NUM_CHANNELS-1:0] ctrlport_radios_resp_ack;
  wire [32*NUM_CHANNELS-1:0] ctrlport_radios_resp_data;

  ctrlport_decoder #(
    .NUM_SLAVES   (NUM_CHANNELS),
    .BASE_ADDR    (0),
    .SLAVE_ADDR_W (RADIO_ADDR_W)
  ) ctrlport_decoder_i (
    .ctrlport_clk            (radio_clk),
    .ctrlport_rst            (radio_rst),
    .s_ctrlport_req_wr       (ctrlport_core_req_wr),
    .s_ctrlport_req_rd       (ctrlport_core_req_rd),
    .s_ctrlport_req_addr     (ctrlport_core_req_addr),
    .s_ctrlport_req_data     (ctrlport_core_req_data),
    .s_ctrlport_req_byte_en  (4'b0),
    .s_ctrlport_req_has_time (1'b0),
    .s_ctrlport_req_time     (64'b0),
    .s_ctrlport_resp_ack     (ctrlport_core_resp_ack),
    .s_ctrlport_resp_status  (),
    .s_ctrlport_resp_data    (ctrlport_core_resp_data),
    .m_ctrlport_req_wr       (ctrlport_radios_req_wr),
    .m_ctrlport_req_rd       (ctrlport_radios_req_rd),
    .m_ctrlport_req_addr     (ctrlport_radios_req_addr),
    .m_ctrlport_req_data     (ctrlport_radios_req_data),
    .m_ctrlport_req_byte_en  (),
    .m_ctrlport_req_has_time (),
    .m_ctrlport_req_time     (),
    .m_ctrlport_resp_ack     (ctrlport_radios_resp_ack),
    .m_ctrlport_resp_status  ({NUM_CHANNELS{2'b00}}),
    .m_ctrlport_resp_data    (ctrlport_radios_resp_data)
  );


  //---------------------------------------------------------------------------
  // Merge Control Port Interfaces
  //---------------------------------------------------------------------------
  //
  // This block merges the master control port interfaces of all radio_cores 
  // into a single master for the NoC shell.
  //
  //---------------------------------------------------------------------------

  wire [   NUM_CHANNELS-1:0] ctrlport_err_radio_req_wr;
  wire [NUM_CHANNELS*20-1:0] ctrlport_err_radio_req_addr;
  wire [NUM_CHANNELS*10-1:0] ctrlport_err_radio_req_portid;
  wire [NUM_CHANNELS*16-1:0] ctrlport_err_radio_req_rem_epid;
  wire [NUM_CHANNELS*10-1:0] ctrlport_err_radio_req_rem_portid;
  wire [NUM_CHANNELS*32-1:0] ctrlport_err_radio_resp_data;
  wire [   NUM_CHANNELS-1:0] ctrlport_err_radio_resp_ack;

  ctrlport_combiner #(
    .NUM_MASTERS (NUM_CHANNELS),
    .PRIORITY    (0)
  ) ctrlport_combiner_i (
    .ctrlport_clk              (radio_clk),
    .ctrlport_rst              (radio_rst),
    .s_ctrlport_req_wr         (ctrlport_err_radio_req_wr),
    .s_ctrlport_req_rd         ({NUM_CHANNELS{1'b0}}),
    .s_ctrlport_req_addr       (ctrlport_err_radio_req_addr),
    .s_ctrlport_req_portid     (ctrlport_err_radio_req_portid),
    .s_ctrlport_req_rem_epid   (ctrlport_err_radio_req_rem_epid),
    .s_ctrlport_req_rem_portid (ctrlport_err_radio_req_rem_portid),
    .s_ctrlport_req_data       (ctrlport_err_radio_resp_data),
    .s_ctrlport_req_byte_en    ({4*NUM_CHANNELS{1'b1}}),
    .s_ctrlport_req_has_time   ({NUM_CHANNELS{1'b0}}),
    .s_ctrlport_req_time       ({NUM_CHANNELS{64'b0}}),
    .s_ctrlport_resp_ack       (ctrlport_err_radio_resp_ack),
    .s_ctrlport_resp_status    (),
    .s_ctrlport_resp_data      (),
    .m_ctrlport_req_wr         (ctrlport_err_req_wr),
    .m_ctrlport_req_rd         (),
    .m_ctrlport_req_addr       (ctrlport_err_req_addr),
    .m_ctrlport_req_portid     (ctrlport_err_req_portid),
    .m_ctrlport_req_rem_epid   (ctrlport_err_req_rem_epid),
    .m_ctrlport_req_rem_portid (ctrlport_err_req_rem_portid),
    .m_ctrlport_req_data       (ctrlport_err_req_data),
    .m_ctrlport_req_byte_en    (),
    .m_ctrlport_req_has_time   (),
    .m_ctrlport_req_time       (),
    .m_ctrlport_resp_ack       (ctrlport_err_resp_ack),
    .m_ctrlport_resp_status    (2'b0),
    .m_ctrlport_resp_data      (32'b0)
  );


  //---------------------------------------------------------------------------
  // Shared Registers
  //---------------------------------------------------------------------------
  //
  // These registers are shared by all radio channels.
  //
  //---------------------------------------------------------------------------

  localparam [15:0] compat_major = 16'd0;
  localparam [15:0] compat_minor = 16'd0;

  always @(posedge radio_clk) begin
    if (radio_rst) begin
      ctrlport_shared_resp_ack  <= 0;
      ctrlport_shared_resp_data <= 0;
    end else begin
      // Default assignments
      ctrlport_shared_resp_ack  <= 0;
      ctrlport_shared_resp_data <= 0;

      // Handle register reads
      if (ctrlport_shared_req_rd) begin
        case (ctrlport_shared_req_addr)
          REG_COMPAT_NUM: begin
            ctrlport_shared_resp_ack  <= 1;
            ctrlport_shared_resp_data <= { compat_major, compat_minor };
          end
        endcase
      end
    end
  end


  //---------------------------------------------------------------------------
  // Radio Cores
  //---------------------------------------------------------------------------
  //
  // This generate block instantiates one radio core for each channel that is
  // requested by NUM_CHANNELS.
  //
  //---------------------------------------------------------------------------

  genvar i;
  generate
    for (i = 0; i < NUM_CHANNELS; i = i+1) begin : radio_core_gen

      // The radio core contains all the logic related to a single radio channel.
      radio_core #(
        .SAMP_W (SAMP_W),
        .NSPC   (NSPC)
      ) radio_core_i (
        .radio_clk                 (radio_clk),
        .radio_rst                 (radio_rst),

        // Slave Control Port (Register Access)
        .s_ctrlport_req_wr         (ctrlport_radios_req_wr[i]),
        .s_ctrlport_req_rd         (ctrlport_radios_req_rd[i]),
        .s_ctrlport_req_addr       (ctrlport_radios_req_addr[i*20 +: 20]),
        .s_ctrlport_req_data       (ctrlport_radios_req_data[i*32 +: 32]),
        .s_ctrlport_resp_ack       (ctrlport_radios_resp_ack[i]),
        .s_ctrlport_resp_data      (ctrlport_radios_resp_data[i*32 +: 32]),

        // Master Control Port (Error Reporting)
        .m_ctrlport_req_wr         (ctrlport_err_radio_req_wr[i]),
        .m_ctrlport_req_addr       (ctrlport_err_radio_req_addr[i*20 +: 20]),
        .m_ctrlport_req_portid     (ctrlport_err_radio_req_portid[i*10 +: 10]),
        .m_ctrlport_req_rem_epid   (ctrlport_err_radio_req_rem_epid[i*16 +: 16]),
        .m_ctrlport_req_rem_portid (ctrlport_err_radio_req_rem_portid[i*10 +: 10]),
        .m_ctrlport_req_data       (ctrlport_err_radio_resp_data[i*32 +: 32]),
        .m_ctrlport_resp_ack       (ctrlport_err_radio_resp_ack[i]),

        // Tx Data Stream
        .s_axis_tdata              (axis_tx_tdata[RADIO_W*i +: RADIO_W]),
        .s_axis_tlast              (axis_tx_tlast[i]),
        .s_axis_tvalid             (axis_tx_tvalid[i]),
        .s_axis_tready             (axis_tx_tready[i]),
        // Sideband Info
        .s_axis_ttimestamp         (axis_tx_ttimestamp[i*64 +: 64]),
        .s_axis_thas_time          (axis_tx_thas_time[i]),
        .s_axis_teob               (axis_tx_teob[i]),

        // Rx Data Stream
        .m_axis_tdata              (axis_rx_tdata[RADIO_W*i +: RADIO_W]),
        .m_axis_tlast              (axis_rx_tlast[i]),
        .m_axis_tvalid             (axis_rx_tvalid[i]),
        .m_axis_tready             (axis_rx_tready[i]),
        // Sideband Info
        .m_axis_ttimestamp         (axis_rx_ttimestamp[i*64 +: 64]),
        .m_axis_teob               (axis_rx_teob[i]),

        // Radio Data
        .radio_time                (radio_time),
        .radio_rx_data             (radio_rx_data[(RADIO_W)*i +: (RADIO_W)]),
        .radio_rx_stb              (radio_rx_stb[i]),
        .radio_rx_running          (radio_rx_running[i]),
        .radio_tx_data             (radio_tx_data[(RADIO_W)*i +: (RADIO_W)]),
        .radio_tx_stb              (radio_tx_stb[i]),
        .radio_tx_running          (radio_tx_running[i])
      );
    end
  endgenerate
endmodule
