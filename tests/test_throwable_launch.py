"""Exercise the loader service in LuaJIT with synthetic memory and recorded calls."""
from pathlib import Path
import struct
import unittest
from lupa.luajit21 import LuaRuntime

SERVICE = Path(__file__).resolve().parents[1] / 'src/throwable_launch.lua'
HOST, DONOR = b'88C2D09AD85A7C9F', b'075B19B068FB1045'


class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.memory = {}
        self.calls = []
        self.game, self.exe = 0x10000000, 0x20000000
        self.next_address = 0x30000000
        self.module = self.lua.execute(SERVICE.read_bytes())
        # Proofs are the same short build signatures used by production.
        proofs = {
            0x615940: '4c8bdc55535657415541564157498daba8f5ffff4881ec200b0000410f2973b8',
            0x6c65f0: '48895c24105556574154415541564157488d6c24804881ec80010000440f29b4',
            0x8cdb40: '405355574883ec403b15d260bb02410fb6e88bda488bf90f8448010000448b49',
            0x8ce620: '405356574883ec203b15f255bb02418bf88bda488bf10f84aa010000448b4140',
            0x1787500: '40534883ec208bdae853ffffff84c00f84ac0000004c8b1dc4f7b9014533c03b',
        }
        for at, value in proofs.items(): self.put(self.game+at, bytes.fromhex(value))
        self.put(self.exe+0x2bd870, bytes.fromhex('488d4160c3'))
        self.explosive = self.alloc(0x100)
        self.q(self.game+0x3326728, self.explosive)
        self.map(self.explosive+0x38, {403: 0})
        self.identity = self.alloc(24)
        self.put(self.identity, struct.pack('<QIIII', int(DONOR,16),403,1,0,1))
        ids = self.alloc(8); self.q(ids,self.identity); self.q(self.explosive+0x50,ids)
        self.state = self.alloc(64); self.q(self.explosive+0x60,self.state)
        self.i(self.state+40,401); self.i(self.state+44,390)
        self.put(self.state+48,b'local123')
        players = self.alloc(160); self.q(self.game+0x3326468,players)
        self.player_count = players+132; self.i(self.player_count,1)
        user = self.alloc(0xb400); self.q(self.game+0x347cef0,user); self.put(user+0xb398,b'local123')
        root = self.alloc(0x1000000); self.q(self.game+0x346bf98,root)
        self.map(root+0xf1aeb0,{401:0,390:1})
        self.source = root+0xf32f18
        self.put(self.source,struct.pack('<QIIII',int(HOST,16),401,2,0,1))
        self.put(self.source+24,struct.pack('<QIIII',123,390,3,0,1))
        fire = self.alloc(0x200); self.q(self.game+0x33266d8,fire)
        self.map(fire+0x50,{401:0}); self.map(fire+0x90,{401:0})
        self.data = self.alloc(616); self.q(fire+0xd0,self.data)
        self.i(self.data,89); self.q(self.data+40,int(DONOR,16))
        records = self.alloc(0xa8); self.q(fire+0x78,records); self.f(records+0x50,1)
        projectile = self.alloc(64); self.q(self.game+0x37c7670+89*8,projectile); self.f(projectile+32,100)
        throwable = self.alloc(100); self.q(self.game+0x33264c0,throwable)
        self.map(throwable+0x30,{403:0})
        registry = self.alloc(200); self.q(self.exe+0x1a100f0,registry); self.i(registry+152,4)
        generations = self.alloc(4); self.q(registry+160,generations)
        objects = self.alloc(32); self.q(registry+136,objects)
        obj = self.alloc(160); self.q(objects+8,obj); self.i(obj+8,1)
        vtable = self.alloc(256); self.q(obj,vtable); self.q(vtable+0xe8,self.exe+0x2bd870)
        self.pose = self.alloc(64); self.q(obj+0x88,self.pose)
        self.put(self.pose,struct.pack('<16f',1,0,0,0,0,1,0,0,0,0,1,0,10,20,30,1))
        wrap = self.lua.eval(b'function(f) return function(a,n) return f(a,n) end end')
        reader = self.lua.table_from({b'read':wrap(self.read)})
        self.query_kind = None
        native = self.lua.table_from({
            b'query':lambda _,kind: int(kind==self.query_kind),
            b'release':lambda *args:self.record('release',args),
            b'start':lambda *args:self.record('start',args),
            b'arm':lambda *args:self.record('arm',args),
        })
        self.service = self.module[b'new'](reader,self.game,self.exe,native)
        self.assertTrue(self.service[b'prove']())
        self.hosts = self.lua.table_from({HOST:True})
        self.donors = self.lua.table_from({DONOR:True})
        self.step() # Baseline existing objects; no callbacks.

    def alloc(self,n):
        at=self.next_address; self.next_address+=n+256
        # Sparse zero-filled allocations avoid a 16 MB Python dictionary.
        return at
    def put(self,at,data):
        self.memory.update({at+i:b for i,b in enumerate(data)})
    def q(self,at,n): self.put(at,struct.pack('<Q',n))
    def i(self,at,n): self.put(at,struct.pack('<I',n))
    def f(self,at,n): self.put(at,struct.pack('<f',n))
    def read(self,at,n): return bytes(self.memory.get(int(at)+i,0) for i in range(int(n)))
    def map(self,at,entries):
        slots=self.alloc(128); self.put(slots,b'\xff'*128)
        self.put(at,struct.pack('<QIII',slots,16,0xffffffff,1))
        for key,value in entries.items(): self.put(slots+(key%16)*8,struct.pack('<II',key,value))
    def record(self,name,args):
        args=list(args)
        if name=='release':
            args[2]=[args[2][i] for i in (1,2,3)]
            args[3]=[args[3][i] for i in (1,2,3)]
        self.calls.append((name,args))
    def step(self): return self.service[b'step'](self.hosts,self.donors)
    def new_shot(self): self.service[b'seen'][403]=None

    def test_baseline_does_not_release_existing_object(self):
        self.step(); self.assertEqual(self.calls,[])
    def test_releases_in_aim_direction_once(self):
        self.new_shot(); self.step(); self.step()
        self.assertEqual([x[0] for x in self.calls],['release','start','arm'])
        self.assertEqual(self.calls[0][1][2:],[ [10,20,30], [0,100,0],390])
        self.assertEqual(self.service[b'released'],1)
    def test_waits_for_owner_initialization(self):
        self.new_shot(); self.i(self.state+44,0); self.step()
        self.assertEqual(self.calls,[])
        self.i(self.state+44,390); self.step(); self.assertEqual(len(self.calls),3)
    def test_never_modifies_normal_hand_throw(self):
        self.new_shot(); self.i(self.state+40,0)
        for _ in range(10): self.step()
        self.assertEqual(self.calls,[])
    def test_rejects_active_explosive(self):
        self.new_shot(); self.put(self.state+1,b'\1'); self.step(); self.assertEqual(self.calls,[])
    def test_rejects_multiplayer(self):
        self.new_shot(); self.i(self.player_count,2); self.step(); self.assertEqual(self.calls,[])
    def test_rejects_remote_owner(self):
        self.new_shot(); self.put(self.state+48,b'remote12'); self.step(); self.assertEqual(self.calls,[])
    def test_requires_matching_selected_grenade(self):
        self.new_shot(); self.q(self.data+40,123); self.step(); self.assertEqual(self.calls,[])
    def test_rejects_invalid_pose(self):
        self.new_shot(); self.f(self.pose+16,9); self.step(); self.assertEqual(self.calls,[])
    def test_uses_alternate_speed_when_enabled(self):
        self.new_shot(); self.query_kind=7; self.f(self.data+0x23c,150); self.step()
        self.assertEqual(self.calls[0][1][3],[0,150,0])
    def test_wrong_build_refuses_proof(self):
        self.service[b'proven']=None; self.put(self.game+0x6c65f0,b'\0')
        self.assertFalse(self.service[b'prove']()[0])


if __name__=='__main__': unittest.main()
