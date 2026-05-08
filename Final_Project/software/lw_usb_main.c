#include <stdio.h>
#include "platform.h"
#include "lw_usb/GenericMacros.h"
#include "lw_usb/GenericTypeDefs.h"
#include "lw_usb/MAX3421E.h"
#include "lw_usb/USB.h"
#include "lw_usb/usb_ch9.h"
#include "lw_usb/transfer.h"
#include "lw_usb/HID.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "hdmi_text_controller.h"

extern HID_DEVICE hid_device;
static BYTE addr = 1; 	//hard-wired USB address
const char* const devclasses[] = {" Uninitialized", " HID Keyboard", " HID Mouse", " Mass storage"};

#define BLOCK(color, height)  (((height) & 0x7) << 4 | ((color) & 0xF))
static const int dir_x[4] = {1,  0, -1,  0};
static const int dir_y[4] = {0,  1,  0, -1};
static const BYTE place_keys[] = {30, 31, 32, 33, 34, 35, 20};
static const uint8_t place_types[] = {0x3, 0x4, 0x5, 0x6, 0x7, 0x8, 0xF};


BYTE GetDriverandReport() {
	BYTE i;
	BYTE rcode;
	BYTE device = 0xFF;
	BYTE tmpbyte;

	DEV_RECORD* tpl_ptr;
	xil_printf("Reached USB_STATE_RUNNING (0x40)\n");
	for (i = 1; i < USB_NUMDEVICES; i++) {
		tpl_ptr = GetDevtable(i);
		if (tpl_ptr->epinfo != NULL) {
			xil_printf("Device: %d", i);
			xil_printf("%s \n", devclasses[tpl_ptr->devclass]);
			device = tpl_ptr->devclass;
		}
	}
	rcode = XferGetIdle(addr, 0, hid_device.interface, 0, &tmpbyte);
	if (rcode) {
		xil_printf("GetIdle Error. Error code: ");
		xil_printf("%x \n", rcode);
	} else {
		xil_printf("Update rate: ");
		xil_printf("%x \n", tmpbyte);
	}
	xil_printf("Protocol: ");
	rcode = XferGetProto(addr, 0, hid_device.interface, &tmpbyte);
	if (rcode) {   //error handling
		xil_printf("GetProto Error. Error code ");
		xil_printf("%x \n", rcode);
	} else {
		xil_printf("%d \n", tmpbyte);
	}
	return device;
}

//This function is written by AI (Claude) mainly the plane_x and plane_y value.
int facing = 1;
static void update_camera(){
    switch (facing & 3) {
        case 0:
            hdmi_ctrl->camera_dir_x   = 0x00010000;
            hdmi_ctrl->camera_dir_y   = 0x00000000;
            hdmi_ctrl->camera_plane_x = 0x00000000;
            hdmi_ctrl->camera_plane_y = 0xFFFF570B;
            break;

        case 1:
            hdmi_ctrl->camera_dir_x   = 0x00000000;
            hdmi_ctrl->camera_dir_y   = 0x00010000;
            hdmi_ctrl->camera_plane_x = 0x0000A8F5;
            hdmi_ctrl->camera_plane_y = 0x00000000;
            break;

        case 2:
            hdmi_ctrl->camera_dir_x   = 0xFFFF0000;
            hdmi_ctrl->camera_dir_y   = 0x00000000;
            hdmi_ctrl->camera_plane_x = 0x00000000;
            hdmi_ctrl->camera_plane_y = 0x0000A8F5;
            break;

        case 3:
            hdmi_ctrl->camera_dir_x   = 0x00000000;
            hdmi_ctrl->camera_dir_y   = 0xFFFF0000;
            hdmi_ctrl->camera_plane_x = 0xFFFF570B;
            hdmi_ctrl->camera_plane_y = 0x00000000;
            break;
    }
}

static void turn_left(){
    facing = (facing + 1) & 3;
    update_camera();
}

static void turn_right(){
    facing = (facing + 3) & 3;
    update_camera();
}

static void move(int dx_steps, int dy_steps){
	int new_x = (int)hdmi_ctrl->player_x + (dx_steps << 16);
	int new_y = (int)hdmi_ctrl->player_y + (dy_steps << 16);
    if (new_x < 0x00008000 || new_x > 0x001F8000 ||
        new_y < 0x00008000 || new_y > 0x001F8000) {
        return;
    }
    int cell_x = new_x >> 16;
    int cell_y = new_y >> 16;
    uint32_t cell = hdmi_ctrl->VRAM[cell_x + Length * cell_y];
    uint8_t cell_height = (cell >> 4) & 0x7;
    if (cell_height > 0) {
        return;
    }
    hdmi_ctrl->player_x = (uint32_t)new_x;
    hdmi_ctrl->player_y = (uint32_t)new_y;
}

static void place_block(uint8_t block_type){
	int target_x = (int)(hdmi_ctrl->player_x >> 16) + dir_x[facing];
	int target_y = (int)(hdmi_ctrl->player_y >> 16) + dir_y[facing];

    if (target_x < 0 || target_x >= Length ||
        target_y < 0 || target_y >= Width) {
        return;
    }

    uint32_t i = target_x + Length * target_y;
    uint32_t tar = hdmi_ctrl->VRAM[i];
    uint8_t height = (tar >> 4) & 0x7;
    if (height < 7) {
        hdmi_ctrl->VRAM[i] = BLOCK(block_type, height + 1);
    }
}

static void delete_block(){
	int target_x = (int)(hdmi_ctrl->player_x >> 16) + dir_x[facing];
	int target_y = (int)(hdmi_ctrl->player_y >> 16) + dir_y[facing];
    if (target_x < 0 || target_x >= Length ||
        target_y < 0 || target_y >= Width) {
        return;
    }
    hdmi_ctrl->VRAM[target_x + Length * target_y] = 0;
}

void init_player(void){
    hdmi_ctrl->player_x = 0x00088000;
    hdmi_ctrl->player_y = 0x00088000;
    facing = 1;
    update_camera();
}

void init_world(void){
    for (int y = 0; y < Width; y++) {
        for (int x = 0; x < Length; x++) {
            hdmi_ctrl->VRAM[x + Length * y] = 0x00000000;
        }
    }
}

int is_key_pressed(BOOT_KBD_REPORT *kbdbuf, BYTE code){
	for(int i = 0; i < 6; i++){
		if(kbdbuf -> keycode[i] == code) return 1;
	}
	return 0;
}

int main() {
    init_platform();

   	BYTE rcode;
	BOOT_KBD_REPORT kbdbuf;

	BYTE runningdebugflag = 0;//flag to dump out a bunch of information when we first get to USB_STATE_RUNNING
	BYTE errorflag = 0; //flag once we get an error device so we don't keep dumping out state info
	BYTE device;

	xil_printf("initializing MAX3421E...\n");
	MAX3421E_init();
	xil_printf("initializing USB...\n");
	USB_init();

	//initialize game
	init_world();
	init_player();

	while (1) {
		MAX3421E_Task();
		USB_Task();
		if (GetUsbTaskState() == USB_STATE_RUNNING) {
			if (!runningdebugflag) {
				runningdebugflag = 1;
				device = GetDriverandReport();
			} else if (device == 1) {
				//run keyboard debug polling
				rcode = kbdPoll(&kbdbuf);
				if (rcode == hrNAK) {
					continue; //NAK means no new data
				} else if (rcode) {
					xil_printf("Rcode: ");
					xil_printf("%x \n", rcode);
					continue;
				}

				//game logic here

				if (is_key_pressed(&kbdbuf, 80))  turn_left();
				if (is_key_pressed(&kbdbuf, 79)) turn_right();
				if (is_key_pressed(&kbdbuf, 26)) move(dir_x[facing], dir_y[facing]); //forward
				if (is_key_pressed(&kbdbuf, 22)) move(-dir_x[facing], -dir_y[facing]); //back
				if (is_key_pressed(&kbdbuf, 4)) move(dir_x[(facing + 1) & 3], dir_y[(facing + 1) & 3]); //left
				if (is_key_pressed(&kbdbuf, 7)) move(dir_x[(facing + 3) & 3], dir_y[(facing + 3) & 3]); //right
				if (is_key_pressed(&kbdbuf, 44)) delete_block();

				//block placement (edge-triggered)
				for (int i = 0; i < 7; i++) {
				    if (is_key_pressed(&kbdbuf, place_keys[i])) place_block(place_types[i]);
				}


				xil_printf("keycodes: ");
				for (int i = 0; i < 6; i++) {
					xil_printf("%x ", kbdbuf.keycode[i]);
				}
				xil_printf("\n");
			}
		} else if (GetUsbTaskState() == USB_STATE_ERROR) {
			if (!errorflag) {
				errorflag = 1;
				xil_printf("USB Error State\n");
			}
		} else //not in USB running state
		{
			xil_printf("USB task state: ");
			xil_printf("%x\n", GetUsbTaskState());
			if (runningdebugflag) {	//previously running, reset USB hardware just to clear out any funky state, HS/FS etc
				runningdebugflag = 0;
				MAX3421E_init();
				USB_init();
			}
			errorflag = 0;
		}
	}

    cleanup_platform();
	return 0;
}
