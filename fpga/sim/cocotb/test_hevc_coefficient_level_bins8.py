import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.chroma_level import coefficient_level_bins_8
from hevc_reference.chroma_syntax import DIAGONAL_SCAN_8, coefficient_scan_metadata_8


async def reset(dut):
    dut.rst_n.value=0;dut.s_valid.value=0;dut.m_ready.value=0
    for _ in range(3):await RisingEdge(dut.clk)
    dut.rst_n.value=1;await RisingEdge(dut.clk)


@cocotb.test()
async def chroma_level_context_sets_and_rice_match_reference(dut):
    cocotb.start_soon(Clock(dut.clk,10,units="ns").start());await reset(dut)
    rng=random.Random(0x1E8E18)
    block=[[0]*8 for _ in range(8)]
    for position,value in ((0,1),(2,-2),(17,5),(19,-1),(36,18),(53,-4)):
        a=DIAGONAL_SCAN_8[position];block[a>>3][a&7]=value
    _,last=coefficient_scan_metadata_8(block);expected=coefficient_level_bins_8(block)
    source=[]
    for p in range(last,-1,-1):
        a=DIAGONAL_SCAN_8[p]
        source.append((block[a>>3][a&7],p>>4,p==last,(p&15)==0,p==0))
    sent=0;received=[];stalled=None;done=False
    for _ in range(10000):
        if not int(dut.s_valid.value) and sent<len(source) and rng.random()<0.85:
            value,g,start,end,lastbit=source[sent]
            dut.s_coefficient.value=value;dut.s_nonzero.value=int(value != 0);dut.s_group_scan_position.value=g
            dut.s_block_start.value=start;dut.s_group_end.value=end
            dut.s_block_last.value=lastbit;dut.s_valid.value=1
        dut.m_ready.value=int(rng.random()<0.7);await RisingEdge(dut.clk)
        output=(int(dut.m_bin.value),int(dut.m_kind.value),bool(dut.m_bypass.value),
                int(dut.m_context_index.value),int(dut.m_group_scan_position.value),
                int(dut.m_coefficient_index.value))
        valid,ready=int(dut.m_valid.value),int(dut.m_ready.value)
        if stalled is not None:assert valid and output==stalled
        stalled=output if valid and not ready else None
        if valid and ready:received.append(output)
        if int(dut.s_valid.value) and int(dut.s_ready.value):sent+=1;dut.s_valid.value=0
        if int(dut.block_done.value):done=True
        if done and len(received)==len(expected):break
    assert received==[(e.value,e.kind,e.bypass,e.context_index,
                       e.group_scan_position,e.coefficient_index) for e in expected]
    assert not int(dut.input_error.value)
