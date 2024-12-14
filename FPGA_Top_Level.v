module FPGA_Top_Level(

//External asynchronous reset from pushbutton 0
input					reset_n,

//Data clock from LTC2335-16 ADC
input					adc_clk_p,

//Data received from LTC2335-16 ADC
input		[15:0]	adc_data_p,

//Clock received from clock chip on AD5764R DAC
//This should match the data rate (i.e. 250 MSPS = 250 MHz clock)
input					dac_clk_p,

//Buttons and switches on board. Functions not yet defined.
//Pushbutton 1 sends a source synchronous sync signal to the DAC.
input		[3:0]		dipswitch,
input		[3:1]		pushbutton,

//Data clock sent to AD5764R DAC
output				dac_data_clk_p,

//Data transmitted to AD5764R DAC
output	[15:0]	dac_data_p,

//Sync signal for the DAC
output				dac_sync_p,

/*LEDs on the Cyclone V GT FPGA development board - Their functions are listed below:

		led[0] = on when RX pll is locked
		led[1] = on when FIFO write side is not empty
		led[2] = on when FIFO write is not full
		led[3] = on when TX pll is locked
		led[4] = on when FIFO read side is not empty
		led[5] = on when FIFO read side is not full
		led[7:6] = always off
 
 Note that LEDs 0 to 5 should be lit during proper operation
*/
output	[7:0]		led

);

//**************************************************
//
// Instantiate the RX clock PLL
// Compensation: rx_pll_clk, source synchronous
// rx_pll_clk 	- 0 degree phase shift
//
//**************************************************

wire rx_pll_clk;
wire rx_pll_locked;

RX_PLL RX_PLL_inst(
	.areset	(!reset_n),
	.inclk0	(adc_clk_p),
	.c0		(rx_pll_clk),
	.locked	(rx_pll_locked)
);


//**************************************************
//
// Instantiate the TX clock PLL
// Compensation: tx_pll_data_clk, normal
// tx_pll_data_clk 	- 0 degree phase shift
// tx_pll_output_clk - 90 degree phase shift
//
//**************************************************

wire tx_pll_data_clk;
wire tx_pll_output_clk;
wire tx_pll_locked;

TX_PLL TX_PLL_inst(
	.areset	(!reset_n),
	.inclk0	(dac_clk_p),
	.c0		(tx_pll_data_clk),
	.c1		(tx_pll_output_clk),
	.locked	(tx_pll_locked)
);


//**************************************************
//
// Transfer the RX/TX PLL lock signals to the TX/RX
// clock domains to control reading and writing into
// the FIFO to prevent full/empty conditions.
//
//**************************************************

reg rx_pll_locked_tx_int;
reg rx_pll_locked_tx_syncd;
reg tx_pll_locked_rx_int;
reg tx_pll_locked_rx_syncd;

always @ (posedge rx_pll_clk)
begin
	tx_pll_locked_rx_int <= tx_pll_locked;
	tx_pll_locked_rx_syncd <= tx_pll_locked_rx_int;
end

always @ (posedge tx_pll_data_clk)
begin
	rx_pll_locked_tx_int <= rx_pll_locked;
	rx_pll_locked_tx_syncd <= rx_pll_locked_tx_int;
end
//**************************************************
//
// Instantiate the RX ALTDDIO function
// Note: see the timing diagram in the app note
//			for a reference of what this is doing
//
//**************************************************

//These wires are used to deinterleave the data from the
//even/odd bit format into 16-bit samples. Since the
//LTC2335-16 is only 16-bits, there is no need to insert zeros for the LSBs.
wire [15:0] rx_chA_sample;
wire [15:0] rx_chB_sample;

//Odd bits are sampled on the rising edge of rx_pll_clk
wire [15:0] altddio_rx_h;

//Even bits are sampled on the falling edge of rx_pll_clk
wire [15:0] altddio_rx_l;

ALTDDIO_RX ALTDDIO_RX_inst(
	.aclr			(!rx_pll_locked),
	.datain 		(adc_data_p),
	.inclock 	(rx_pll_clk),
	.dataout_h	(altddio_rx_h),
	.dataout_l	(altddio_rx_l)
);

//Deinterleaving the output of the ALTDDIO function
//and inserting zeros for the two LSBs
assign rx_chA_sample[15:0] = altddio_rx_h;
assign rx_chB_sample[15:0] = altddio_rx_l;

 
//**************************************************
//
// Instantiate the RX to TX FIFO to allow transfer
// of data between clock domains. This is necessary
// because phase differences between lvds_rx_pll_clk
// and lvds_tx_fpga_clk are unknown. The two external
// clocks should be externally synchronized to avoid
// FIFO collision errors.
//
//**************************************************

wire tx_to_rx_read_empty;
wire tx_to_rx_write_empty;
wire tx_to_rx_read_full;
wire tx_to_rx_write_full;

wire [15:0] tx_chA_sample;
wire [15:0] tx_chB_sample;

RX_to_TX_FIFO RX_to_TX_FIFO_inst(
	.aclr 	(!reset_n),
	.data 	({rx_chA_sample[15:0],rx_chB_sample[15:0]}),
	.rdclk 	(tx_pll_data_clk),
	.rdreq 	(tx_pll_locked && rx_pll_locked_tx_syncd),
	.wrclk 	(rx_pll_clk),
	.wrreq 	(rx_pll_locked && tx_pll_locked_rx_syncd),
	.q 		({tx_chA_sample[15:0],tx_chB_sample[15:0]}),
	.rdempty (tx_to_rx_read_empty),
	.rdfull	(tx_to_rx_read_full),
	.wrempty (tx_to_rx_write_empty),
	.wrfull	(tx_to_rx_write_full)
);


//**************************************************
//
// Create a synchronized DAC sync signal from
// the external push buttons. It is synchronized
// to the TX clock domain using tx_pll_data_clk.
//
// Additionally, a debounce counter is utilized to
// prevent multiple sync presses.
//
//**************************************************

reg reset_tx_int_n;
reg reset_tx_syncd_n;

always @ (posedge tx_pll_data_clk)
begin
	reset_tx_int_n <= reset_n;
	reset_tx_syncd_n <= reset_tx_int_n;
end

reg sync_button_int;
reg sync_button_tx_syncd;
reg dac_sync_signal;

always @ (posedge tx_pll_data_clk)
begin
	sync_button_int <= !pushbutton[1];
	sync_button_tx_syncd <= sync_button_int;
end

reg [15:0] debounce_dac_sync_counter;
always @ (posedge tx_pll_data_clk)
begin
	if(!reset_tx_syncd_n) begin
		debounce_dac_sync_counter <= 16'd0;
		dac_sync_signal <= 1'b0;
	end else begin
		if(debounce_dac_sync_counter != 16'd65535) begin
			debounce_dac_sync_counter <= debounce_dac_sync_counter + 16'd1;
		end else begin
			if(dac_sync_signal != sync_button_tx_syncd) begin
				debounce_dac_sync_counter <= 16'd0;
				dac_sync_signal <= sync_button_tx_syncd;
			end
		end
	end
end


//**************************************************
//
// Instantiate the output ALTDDIO functions. One is
// used for the data and sync signal and another is
// used to generate the clock.
//
//**************************************************

//Cannot generate a 17-bit ALTDDIO output function,
//so an 18-bit ALTDDIO is created and a dummy wire
//is used on the last bit to allow compilation
wire dummy;

ALTDDIO_TX ALTDDIO_TX_inst(
	.aclr (!tx_pll_locked),
	.datain_h ({tx_chA_sample[15:0],dac_sync_signal,1'b0}),
	.datain_l ({tx_chB_sample[15:0],dac_sync_signal,1'b0}),
	.outclock (tx_pll_data_clk),
	.dataout ({dac_data_p[15:0],dac_sync_p,dummy})
);


//**************************************************
//
//	The DAC data clock (dac_data_clk_p) is generated
//	using a 1-bit ALTDDIO function where the high and low
//	inputs are tied high and low, respectively. This architecture
//	eases timing closure between the clock and data, especially over
//	temperature. The clock used for this function is phase shifted
//	90 degrees using the TX PLL to create a center-aligned
//	source synchronous interface.
//
//**************************************************

ALTDDIO_CLK_OUT ALTDDIO_CLK_OUT_inst(
	.datain_h (1'b1),
	.datain_l (1'b0),
	.outclock (tx_pll_output_clk),
	.outclocken (tx_pll_locked),
	.dataout (dac_data_clk_p)
);


// Set status LEDs for visual feedback.
// The functions are defined in the module input/output definitions.
assign led[0] = ~rx_pll_locked;
assign led[1] = tx_to_rx_write_empty;
assign led[2] = tx_to_rx_write_full;
assign led[3] = reset_n;
assign led[4] = ~tx_pll_locked;
assign led[5] = tx_to_rx_read_empty;
assign led[6] = tx_to_rx_read_full;
assign led[7] = !dac_sync_signal;

endmodule