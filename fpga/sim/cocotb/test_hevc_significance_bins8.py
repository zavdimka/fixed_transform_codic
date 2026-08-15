import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from hevc_reference.chroma_syntax import (
    DIAGONAL_SCAN_8, coefficient_scan_metadata_8, significance_bins_8,
)


async def reset(dut):
    dut.rst_n.value=0;dut.s_valid.value=0;dut.m_ready.value=0
    for _ in range(3):await RisingEdge(dut.clk)
    dut.rst_n.value=1;await RisingEdge(dut.clk)


@cocotb.test()
async def chroma_significance_contexts_match_reference(dut):
    cocotb.start_soon(Clock(dut.clk,10,units="ns").start());await reset(dut)
    rng=random.Random(0x5188)
    blocks=[]
    sparse=[[0]*8 for _ in range(8)]
    for p,v in ((0,1),(17,-2),(36,3),(53,-4)):
        a=DIAGONAL_SCAN_8[p];sparse[a>>3][a&7]=v
    blocks.append(sparse)
    blocks.append([[rng.randrange(-2,3) if rng.random()<0.2 else 0 for _ in range(8)] for _ in range(8)])
    for block in blocks:
        flags,last=coefficient_scan_metadata_8(block);assert last is not None
        expected=significance_bins_8(block);source=[]
        for p in range(last,-1,-1):
            a=DIAGONAL_SCAN_8[p]
            source.append((a,p,block[a>>3][a&7],flags[(0,2,1,3)[p>>4]],p==0))
        sent=0;received=[];stalled=None;done=False
        for _ in range(5000):
            if not int(dut.s_valid.value) and sent<len(source) and rng.random()<0.85:
                a,p,v,g,lastbit=source[sent]
                dut.s_raster_address.value=a;dut.s_scan_position.value=p
                dut.s_coefficient.value=v;dut.s_group_nonzero.value=g
                dut.s_significant_group_flags.value=sum(int(x)<<i for i,x in enumerate(flags))
                dut.s_block_last.value=lastbit;dut.s_valid.value=1
            dut.m_ready.value=int(rng.random()<0.7);await RisingEdge(dut.clk)
            output=(int(dut.m_bin.value),bool(dut.m_coded_sub_block.value),
                    int(dut.m_context_index.value),int(dut.m_scan_position.value))
            valid,ready=int(dut.m_valid.value),int(dut.m_ready.value)
            if stalled is not None:assert valid and output==stalled
            stalled=output if valid and not ready else None
            if valid and ready:received.append(output)
            if int(dut.s_valid.value) and int(dut.s_ready.value):sent+=1;dut.s_valid.value=0
            if int(dut.stage_done.value):done=True
            if done and len(received)==len(expected):break
        assert received==[(e.value,e.coded_sub_block,e.context_index,e.scan_position) for e in expected]
        assert not int(dut.input_error.value)
