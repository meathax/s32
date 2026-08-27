import unittest
from hle_oracle import *
class OracleTest(unittest.TestCase):
	def test_exact_packet_layout(self):
		s=bytearray(0x800); s[3]=1; s[0x480:0x500]=bytes(range(128))
		p=tx_packets(s,2,False)
		self.assertEqual(p[0], bytes([2])+bytes(range(128))); self.assertEqual(s[3],0)
	def test_receive_and_master_packets(self):
		s=bytearray(0x800); p=bytes([2])+bytes([0xa5])*128
		self.assertTrue(receive(s,p,1,2,False)); self.assertEqual(s[0x100:0x180],bytes([0xa5])*128)
		s[3]=1; out=tx_packets(s,1,True)
		self.assertEqual([x[0] for x in out],[1,0xfd,0xfc]); self.assertTrue(all(len(x)==129 for x in out))
if __name__ == '__main__': unittest.main()
