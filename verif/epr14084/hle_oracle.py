"""Semantic oracle for MAME 0.289 comm_tick_14084; not native device cycles."""
FRAME_START, FRAME_SIZE = 0x480, 0x80

def tx_packets(shared, link_id, master):
	packets = []
	if link_id and shared[3]:
		packets.append(bytes([link_id]) + bytes(shared[FRAME_START:FRAME_START+FRAME_SIZE]))
	if link_id and master:
		packets.append(bytes([0xfd]) + bytes(shared[5:0x10]) + bytes(FRAME_SIZE-11))
		packets.append(bytes([0xfc, 1]) + bytes(FRAME_SIZE-1))
	shared[3] = 0
	return packets

def receive(shared, packet, link_id, link_count, master):
	idx = packet[0]
	if 0 < idx <= link_count and idx != link_id:
		start = idx * FRAME_SIZE
		shared[start:start+FRAME_SIZE] = packet[1:1+FRAME_SIZE]
		return True
	if idx == 0xfd and not master:
		shared[5:0x10] = packet[1:12]
		return True
	return idx == 0xfc
