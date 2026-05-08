`timescale 1 ns / 1 ps
module raycaster_engine(
  input logic clk,
    input logic reset,
  input logic signed [31:0] player_x,player_y,player_z,
input logic signed [31:0] dir_x,dir_y,plane_x,plane_y,
   output logic [9:0] map_addrb,
    input logic [31:0] map_doutb,
  output logic [17:0] vram_w_addr,
 output logic [3:0] vram_w_data,
    output logic vram_we,
  output logic write_buffer
);

// states
enum logic [4:0] {INIT,DRAW_BG,CALC_RAY_MUL,CALC_RAY_ADD,CALC_STEP,DIV_DDX_INIT,WAIT_DDX,
DIV_DDY_INIT,WAIT_DDY,SETUP_STEP_MUL,SETUP_STEP_ASSIGN,DDA_STEP,DDA_BRAM_WAIT,DDA_CHECK,
CALC_DIST,DIV_HEIGHT_INIT,WAIT_HEIGHT,CALC_HEIGHT_MUL,CALC_HEIGHT_ADD,DRAW_SEG} state;

logic [8:0] screen_x;
   logic [7:0] screen_y;

logic signed [31:0] cameraX,rayDirX,rayDirY;
 logic signed [31:0] mapX,mapY;
logic signed [31:0] sideDistX,sideDistY,deltaDistX,deltaDistY;
  logic signed [31:0] perpWallDist;

logic signed [31:0] stepX,stepY;
  logic hit,side;
logic [3:0] hit_color;
   logic [2:0] hit_height;
logic [6:0] depth_count;
logic [7:0] drawStart,drawEnd;
   logic [15:0] hit_fraction;
logic [31:0] abs_dir_x,abs_dir_y;

logic signed [63:0] calc_ray_mul_x,calc_ray_mul_y;
  logic signed [63:0] setup_step_mul_x,setup_step_mul_y;
 logic signed [63:0] hit_frac_mul_res;
logic signed [31:0] saved_line_height;
logic signed [31:0] nextMapX,nextMapY;

logic div_valid_in;
   logic div_valid_out;
logic [63:0] div_num;
  logic [31:0] div_den;
logic [95:0] div_result;

logic [8:0] clip_y;
  logic [7:0] drawSegStart;
logic [7:0] drawSegEnd;
   logic ray_stop_after_hit;

div_gen_0 hardware_divider(
  .aclk(clk),
   .s_axis_divisor_tvalid(div_valid_in),
    .s_axis_divisor_tdata(div_den),
  .s_axis_dividend_tvalid(div_valid_in),
   .s_axis_dividend_tdata(div_num),
    .m_axis_dout_tvalid(div_valid_out),
  .m_axis_dout_tdata(div_result)
);

// change color shadow stuff this one ai generated
function automatic [3:0] shade_dark(input logic [3:0] c);
  case(c)
    4'h0:shade_dark=4'h0;
      4'h1:shade_dark=4'h1;
    4'h2:shade_dark=4'h2;
       4'h3:shade_dark=4'h9;
    4'h4:shade_dark=4'hA;
     4'h5:shade_dark=4'hB;
    4'h6:shade_dark=4'hC;
        4'h7:shade_dark=4'hD;
    4'h8:shade_dark=4'hE;
       4'h9:shade_dark=4'h9;
    4'hA:shade_dark=4'hA;
      4'hB:shade_dark=4'hB;
    4'hC:shade_dark=4'hC;
        4'hD:shade_dark=4'hD;
    4'hE:shade_dark=4'hE;
      4'hF:shade_dark=4'hF;
    default:shade_dark=4'h0;
  endcase
endfunction

// big state machine go here
always_ff @(posedge clk) begin
  if(reset) begin
    state<=INIT;
       screen_x<=0;
    vram_we<=0;
      div_valid_in<=0;
    hit_height<=3'd0;
       clip_y<=9'd240;
    drawSegStart<=8'd0;
       drawSegEnd<=8'd0;
    ray_stop_after_hit<=1'b0;
      write_buffer<=1'b0;
  end else begin
    vram_we<=0;

    case(state)
      INIT:begin
        if(screen_x<320) begin
             screen_y<=8'd0;
          state<=DRAW_BG;
        end else begin
             screen_x<=9'd0;
          write_buffer<=~write_buffer;
        end
      end
      
      DRAW_BG:begin
        if(write_buffer)
             vram_w_addr<=(screen_y*320)+screen_x+18'd76800;
        else
             vram_w_addr<=(screen_y*320)+screen_x;

        vram_we<=1'b1;
        
        if(screen_y<8'd120)
             vram_w_data<=4'h0;
        else
             vram_w_data<=4'h2;
        
        if(screen_y==8'd239) begin
             cameraX<=((screen_x<<17)/320)-(1<<16);
          mapX<=player_x[31:16];
             mapY<=player_y[31:16];
          hit<=1'b0;
             depth_count<=7'd0;
          clip_y<=9'd240;
             ray_stop_after_hit<=1'b0;
          state<=CALC_RAY_MUL;
        end else begin
             screen_y<=screen_y+1'b1;
        end
      end
      
      CALC_RAY_MUL:begin
           calc_ray_mul_x<=64'(plane_x)*64'(cameraX);
        calc_ray_mul_y<=64'(plane_y)*64'(cameraX);
           state<=CALC_RAY_ADD;
      end

      CALC_RAY_ADD:begin
           rayDirX<=dir_x+calc_ray_mul_x[47:16];
        rayDirY<=dir_y+calc_ray_mul_y[47:16];
           state<=CALC_STEP;
      end

      CALC_STEP:begin
           abs_dir_x<=(rayDirX<0)?-rayDirX:rayDirX;
        abs_dir_y<=(rayDirY<0)?-rayDirY:rayDirY;
           state<=DIV_DDX_INIT;
      end

      DIV_DDX_INIT:begin
        if(abs_dir_x<32'd16) begin
             deltaDistX<=32'h0FFFFFFF;
          state<=DIV_DDY_INIT;
        end else begin
             div_num<=64'h0000000100000000;
          div_den<=abs_dir_x;
             div_valid_in<=1'b1;
          state<=WAIT_DDX;
        end
      end

      WAIT_DDX:begin
           div_valid_in<=1'b0;
        if(div_valid_out) begin
             deltaDistX<=div_result[63:32];
          state<=DIV_DDY_INIT;
        end
      end

      DIV_DDY_INIT:begin
        if(abs_dir_y<32'd16) begin
             deltaDistY<=32'h0FFFFFFF;
          state<=SETUP_STEP_MUL;
        end else begin
             div_num<=64'h0000000100000000;
          div_den<=abs_dir_y;
             div_valid_in<=1'b1;
          state<=WAIT_DDY;
        end
      end

      WAIT_DDY:begin
           div_valid_in<=1'b0;
        if(div_valid_out) begin
             deltaDistY<=div_result[63:32];
          state<=SETUP_STEP_MUL;
        end
      end

      SETUP_STEP_MUL:begin
           automatic logic signed [31:0] px_frac;
        automatic logic signed [31:0] py_frac;

           px_frac=player_x&32'h0000FFFF;
        py_frac=player_y&32'h0000FFFF;

        if(rayDirX<0) begin
             stepX<=-1;
          setup_step_mul_x<=64'(px_frac)*64'(deltaDistX);
        end else begin
             stepX<=1;
          setup_step_mul_x<=64'(32'h00010000-px_frac)*64'(deltaDistX);
        end

        if(rayDirY<0) begin
             stepY<=-1;
          setup_step_mul_y<=64'(py_frac)*64'(deltaDistY);
        end else begin
             stepY<=1;
          setup_step_mul_y<=64'(32'h00010000-py_frac)*64'(deltaDistY);
        end
           state<=SETUP_STEP_ASSIGN;
      end

      SETUP_STEP_ASSIGN:begin
           sideDistX<=setup_step_mul_x[47:16];
        sideDistY<=setup_step_mul_y[47:16];
           state<=DDA_STEP;
      end

      DDA_STEP:begin
           automatic logic signed [31:0] tempNextMapX;
        automatic logic signed [31:0] tempNextMapY;

           depth_count<=depth_count+1;

        if(depth_count>64||clip_y==9'd0) begin
             screen_x<=screen_x+1'b1;
          state<=INIT;
        end else begin
             tempNextMapX=mapX;
          tempNextMapY=mapY;

          if(sideDistX<sideDistY) begin
               tempNextMapX=mapX+stepX;
            sideDistX<=sideDistX+deltaDistX;
               side<=0;
          end else begin
               tempNextMapY=mapY+stepY;
            sideDistY<=sideDistY+deltaDistY;
               side<=1;
          end

             nextMapX<=tempNextMapX;
          nextMapY<=tempNextMapY;
             map_addrb<=(tempNextMapY[4:0]*32)+tempNextMapX[4:0];
          state<=DDA_BRAM_WAIT;
        end
      end

      DDA_BRAM_WAIT:begin
           mapX<=nextMapX;
        mapY<=nextMapY;
           state<=DDA_CHECK;
      end

      // dda checks here
      DDA_CHECK:begin
        if(nextMapX<=0||nextMapX>=31||nextMapY<=0||nextMapY>=31) begin
             hit<=1'b1;
          hit_color<=4'h1;
             hit_height<=3'd7;
          ray_stop_after_hit<=1'b1;
             state<=CALC_DIST;
        end else if(map_doutb[6:4]!=3'd0) begin
             hit<=1'b1;
          hit_color<=map_doutb[3:0];
             hit_height<=map_doutb[6:4];
          ray_stop_after_hit<=1'b0;
             state<=CALC_DIST;
        end else begin
             state<=DDA_STEP;
        end
      end

      CALC_DIST:begin
        if(side==0) perpWallDist<=sideDistX-deltaDistX;
        else perpWallDist<=sideDistY-deltaDistY;
           state<=DIV_HEIGHT_INIT;
      end

      DIV_HEIGHT_INIT:begin
           div_num<={32'd0,32'd15728640};
        div_den<=(perpWallDist<=0)?32'd1:perpWallDist;
           div_valid_in<=1'b1;
        state<=WAIT_HEIGHT;
      end

      WAIT_HEIGHT:begin
           div_valid_in<=1'b0;
        if(div_valid_out) begin
             saved_line_height<=div_result[63:32];
          state<=CALC_HEIGHT_MUL;
        end
      end

      CALC_HEIGHT_MUL:begin
           automatic logic signed [31:0] safe_dist;
        safe_dist=(perpWallDist<=0)?32'd1:perpWallDist;

        if(side==0) hit_frac_mul_res<=64'(safe_dist)*64'(rayDirY);
        else hit_frac_mul_res<=64'(safe_dist)*64'(rayDirX);

           state<=CALC_HEIGHT_ADD;
      end

      CALC_HEIGHT_ADD:begin
           automatic logic signed [31:0] exact_hit;
        automatic logic signed [31:0] ds,de;
           automatic logic signed [31:0] wall_pixels;
        automatic logic [8:0] c_ds,c_de;
        
        if(side==0)
             exact_hit=player_y+hit_frac_mul_res[47:16];
        else
             exact_hit=player_x+hit_frac_mul_res[47:16];
        
           hit_fraction<=exact_hit[15:0];
        
        wall_pixels=saved_line_height*$signed({29'd0,hit_height});
        
           de=32'sd120+saved_line_height;
        ds=de-wall_pixels;
        
        if(ds<0) c_ds=9'd0;
        else if(ds>239) c_ds=9'd239;
        else c_ds=ds[8:0];
        
        if(de<0) c_de=9'd0;
        else if(de>239) c_de=9'd239;
        else c_de=de[8:0];
        
           drawStart<=c_ds[7:0];
        drawEnd<=c_de[7:0];
        
        if(hit_height==3'd0||c_ds>c_de) begin
          if(ray_stop_after_hit) begin
               screen_x<=screen_x+1'b1;
            state<=INIT;
          end else begin
               state<=DDA_STEP;
          end
        end else if(c_ds<clip_y) begin
             drawSegStart<=c_ds[7:0];
          
          if(c_de>=clip_y)
               drawSegEnd<=clip_y[7:0]-8'd1;
          else
               drawSegEnd<=c_de[7:0];
          
             screen_y<=c_ds[7:0];
          clip_y<=c_ds;
             state<=DRAW_SEG;
        end else begin
          if(ray_stop_after_hit) begin
               screen_x<=screen_x+1'b1;
            state<=INIT;
          end else begin
               state<=DDA_STEP;
          end
        end
      end

      // draw it on screen
      DRAW_SEG:begin
           automatic logic [3:0] wall_color;
        
        wall_color=(side==1)?shade_dark(hit_color):hit_color;
        
        if(perpWallDist>32'h00060000)
             wall_color=shade_dark(shade_dark(wall_color));
        else if(perpWallDist>32'h00030000)
             wall_color=shade_dark(wall_color);
        
        if(write_buffer)
             vram_w_addr<=(screen_y*320)+screen_x+18'd76800;
        else
             vram_w_addr<=(screen_y*320)+screen_x;

           vram_we<=1'b1;
        vram_w_data<=wall_color;
        
        if(screen_y==drawSegEnd) begin
          if(ray_stop_after_hit||clip_y==9'd0) begin
               screen_x<=screen_x+1'b1;
            state<=INIT;
          end else begin
               state<=DDA_STEP;
          end
        end else begin
             screen_y<=screen_y+1'b1;
        end
      end
    endcase
  end
end

endmodule