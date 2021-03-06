//===-- HexagonVectorPrint.cpp - Generate vector printing instructions -===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// This pass adds the capability to generate pseudo vector/predicate register
// printing instructions. These pseudo instructions should be used with the
// simulator, NEVER on hardware.
//
//===----------------------------------------------------------------------===//

#define DEBUG_TYPE "hexagon-vector-print"

#include "HexagonTargetMachine.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"

using namespace llvm;

static cl::opt<bool> TraceHexVectorStoresOnly("trace-hex-vector-stores-only",
  cl::Hidden, cl::ZeroOrMore, cl::init(false),
  cl::desc("Enables tracing of vector stores"));

namespace llvm {
  FunctionPass *createHexagonVectorPrint();
  void initializeHexagonVectorPrintPass(PassRegistry&);
}


namespace {

class HexagonVectorPrint : public MachineFunctionPass {
    const HexagonSubtarget     *QST;
    const HexagonInstrInfo     *QII;
    const HexagonRegisterInfo  *QRI;

 public:
    static char ID;
    HexagonVectorPrint() : MachineFunctionPass(ID),
      QST(0), QII(0), QRI(0) {
      initializeHexagonVectorPrintPass(*PassRegistry::getPassRegistry());
    }

    const char *getPassName() const override {
      return "Hexagon VectorPrint pass";
    }
    bool runOnMachineFunction(MachineFunction &Fn) override;
};

char HexagonVectorPrint::ID = 0;

static bool isVecReg(unsigned Reg) {
  return (Reg >= Hexagon::V0 && Reg <= Hexagon::V31)
      || (Reg >= Hexagon::W0 && Reg <= Hexagon::W15)
      || (Reg >= Hexagon::Q0 && Reg <= Hexagon::Q3);
}

std::string getStringReg(unsigned R) {
  if (R >= Hexagon::V0 && R <= Hexagon::V31) {
    static const char* S[] = { "20", "21", "22", "23", "24", "25", "26", "27",
                        "28", "29", "2a", "2b", "2c", "2d", "2e", "2f",
                        "30", "31", "32", "33", "34", "35", "36", "37",
                        "38", "39", "3a", "3b", "3c", "3d", "3e", "3f"};
    return S[R-Hexagon::V0];
  }
  if (R >= Hexagon::Q0 && R <= Hexagon::Q3) {
    static const char* S[] = { "00", "01", "02", "03"};
    return S[R-Hexagon::Q0];

  }
  llvm_unreachable("valid vreg");
}

static void addAsmInstr(MachineBasicBlock *MBB, unsigned Reg,
                        MachineBasicBlock::instr_iterator I,
                        const DebugLoc &DL, const HexagonInstrInfo *QII,
                        MachineFunction &Fn) {

  std::string VDescStr = ".long 0x1dffe0" + getStringReg(Reg);
  const char *cstr = Fn.createExternalSymbolName(VDescStr.c_str());
  unsigned ExtraInfo = InlineAsm::Extra_HasSideEffects;
  BuildMI(*MBB, I, DL, QII->get(TargetOpcode::INLINEASM))
    .addExternalSymbol(cstr)
    .addImm(ExtraInfo);
}

static bool getInstrVecReg(const MachineInstr &MI, unsigned &Reg) {
  if (MI.getNumOperands() < 1) return false;
  // Vec load or compute.
  if (MI.getOperand(0).isReg() && MI.getOperand(0).isDef()) {
    Reg = MI.getOperand(0).getReg();
    if (isVecReg(Reg))
      return !TraceHexVectorStoresOnly;
  }
  // Vec store.
  if (MI.mayStore() && MI.getNumOperands() >= 3 && MI.getOperand(2).isReg()) {
    Reg = MI.getOperand(2).getReg();
    if (isVecReg(Reg))
      return true;
  }
  // Vec store post increment.
  if (MI.mayStore() && MI.getNumOperands() >= 4 && MI.getOperand(3).isReg()) {
    Reg = MI.getOperand(3).getReg();
    if (isVecReg(Reg))
      return true;
  }
  return false;
}

bool HexagonVectorPrint::runOnMachineFunction(MachineFunction &Fn) {
  bool Changed = false;
  QST = &Fn.getSubtarget<HexagonSubtarget>();
  QRI = QST->getRegisterInfo();
  QII = QST->getInstrInfo();
  std::vector<MachineInstr *> VecPrintList;
  for (auto &MBB : Fn)
    for (auto &MI : MBB) {
      if (MI.isBundle()) {
        MachineBasicBlock::instr_iterator MII = MI.getIterator();
        for (++MII; MII != MBB.instr_end() && MII->isInsideBundle(); ++MII) {
          if (MII->getNumOperands() < 1)
            continue;
          unsigned Reg = 0;
          if (getInstrVecReg(*MII, Reg)) {
            VecPrintList.push_back((&*MII));
            DEBUG(dbgs() << "Found vector reg inside bundle \n"; MII->dump());
          }
        }
      } else {
        unsigned Reg = 0;
        if (getInstrVecReg(MI, Reg)) {
          VecPrintList.push_back(&MI);
          DEBUG(dbgs() << "Found vector reg \n"; MI.dump());
        }
      }
    }

  Changed = VecPrintList.size() > 0;
  if (!Changed)
    return Changed;

  for (auto *I : VecPrintList) {
    DebugLoc DL = I->getDebugLoc();
    MachineBasicBlock *MBB = I->getParent();
    DEBUG(dbgs() << "Evaluating V MI\n"; I->dump());
    unsigned Reg = 0;
    if (!getInstrVecReg(*I, Reg))
      llvm_unreachable("Need a vector reg");
    MachineBasicBlock::instr_iterator MII = I->getIterator();
    if (I->isInsideBundle()) {
      DEBUG(dbgs() << "add to end of bundle\n"; I->dump());
      while (MBB->instr_end() != MII && MII->isInsideBundle())
        MII++;
    } else {
      DEBUG(dbgs() << "add after instruction\n"; I->dump());
      MII++;
    }
    if (MBB->instr_end() == MII)
      continue;

    if (Reg >= Hexagon::V0 && Reg <= Hexagon::V31) {
      DEBUG(dbgs() << "adding dump for V" << Reg-Hexagon::V0 << '\n');
      addAsmInstr(MBB, Reg, MII, DL, QII, Fn);
    } else if (Reg >= Hexagon::W0 && Reg <= Hexagon::W15) {
      DEBUG(dbgs() << "adding dump for W" << Reg-Hexagon::W0 << '\n');
      addAsmInstr(MBB, Hexagon::V0 + (Reg - Hexagon::W0) * 2 + 1,
                  MII, DL, QII, Fn);
      addAsmInstr(MBB, Hexagon::V0 + (Reg - Hexagon::W0) * 2,
                   MII, DL, QII, Fn);
    } else if (Reg >= Hexagon::Q0 && Reg <= Hexagon::Q3) {
      DEBUG(dbgs() << "adding dump for Q" << Reg-Hexagon::Q0 << '\n');
      addAsmInstr(MBB, Reg, MII, DL, QII, Fn);
    } else
      llvm_unreachable("Bad Vector reg");
  }
  return Changed;
}

}
//===----------------------------------------------------------------------===//
//                         Public Constructor Functions
//===----------------------------------------------------------------------===//
INITIALIZE_PASS(HexagonVectorPrint, "hexagon-vector-print",
  "Hexagon VectorPrint pass", false, false)

FunctionPass *llvm::createHexagonVectorPrint() {
  return new HexagonVectorPrint();
}
