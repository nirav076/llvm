; RUN: llc < %s -march=nvptx64 -mcpu=sm_35 | FileCheck %s --check-prefix PTX
; RUN: opt < %s -S -nvptx-lower-aggr-copies | FileCheck %s --check-prefix IR

; Verify that the NVPTXLowerAggrCopies pass works as expected - calls to
; llvm.mem* intrinsics get lowered to loops.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
target triple = "nvptx64-unknown-unknown"

declare void @llvm.memcpy.p0i8.p0i8.i64(i8* nocapture, i8* nocapture readonly, i64, i32, i1) #1
declare void @llvm.memmove.p0i8.p0i8.i64(i8* nocapture, i8* nocapture readonly, i64, i32, i1) #1
declare void @llvm.memset.p0i8.i64(i8* nocapture, i8, i64, i32, i1) #1

define i8* @memcpy_caller(i8* %dst, i8* %src, i64 %n) #0 {
entry:
  tail call void @llvm.memcpy.p0i8.p0i8.i64(i8* %dst, i8* %src, i64 %n, i32 1, i1 false)
  ret i8* %dst

; IR-LABEL:   @memcpy_caller
; IR:         loadstoreloop:
; IR:         [[LOADPTR:%[0-9]+]] = getelementptr inbounds i8, i8* %src, i64
; IR-NEXT:    [[VAL:%[0-9]+]] = load i8, i8* [[LOADPTR]]
; IR-NEXT:    [[STOREPTR:%[0-9]+]] = getelementptr inbounds i8, i8* %dst, i64
; IR-NEXT:    store i8 [[VAL]], i8* [[STOREPTR]]

; PTX-LABEL:  .visible .func (.param .b64 func_retval0) memcpy_caller
; PTX:        LBB[[LABEL:[_0-9]+]]:
; PTX:        ld.u8 %rs[[REG:[0-9]+]]
; PTX:        st.u8 [%rd{{[0-9]+}}], %rs[[REG]]
; PTX:        add.s64 %rd[[COUNTER:[0-9]+]], %rd[[COUNTER]], 1
; PTX-NEXT:   setp.lt.u64 %p[[PRED:[0-9]+]], %rd[[COUNTER]], %rd
; PTX-NEXT:   @%p[[PRED]] bra LBB[[LABEL]]
}

define i8* @memcpy_volatile_caller(i8* %dst, i8* %src, i64 %n) #0 {
entry:
  tail call void @llvm.memcpy.p0i8.p0i8.i64(i8* %dst, i8* %src, i64 %n, i32 1, i1 true)
  ret i8* %dst

; IR-LABEL:   @memcpy_volatile_caller
; IR:         load volatile
; IR:         store volatile

; PTX-LABEL:  .visible .func (.param .b64 func_retval0) memcpy_volatile_caller
; PTX:        LBB[[LABEL:[_0-9]+]]:
; PTX:        ld.volatile.u8 %rs[[REG:[0-9]+]]
; PTX:        st.volatile.u8 [%rd{{[0-9]+}}], %rs[[REG]]
; PTX:        add.s64 %rd[[COUNTER:[0-9]+]], %rd[[COUNTER]], 1
; PTX-NEXT:   setp.lt.u64 %p[[PRED:[0-9]+]], %rd[[COUNTER]], %rd
; PTX-NEXT:   @%p[[PRED]] bra LBB[[LABEL]]
}

define i8* @memcpy_casting_caller(i32* %dst, i32* %src, i64 %n) #0 {
entry:
  %0 = bitcast i32* %dst to i8*
  %1 = bitcast i32* %src to i8*
  tail call void @llvm.memcpy.p0i8.p0i8.i64(i8* %0, i8* %1, i64 %n, i32 1, i1 false)
  ret i8* %0

; Check that casts in calls to memcpy are handled properly
; IR-LABEL:   @memcpy_casting_caller
; IR:         [[DSTCAST:%[0-9]+]] = bitcast i32* %dst to i8*
; IR:         [[SRCCAST:%[0-9]+]] = bitcast i32* %src to i8*
; IR:         getelementptr inbounds i8, i8* [[SRCCAST]]
; IR:         getelementptr inbounds i8, i8* [[DSTCAST]]
}

define i8* @memset_caller(i8* %dst, i32 %c, i64 %n) #0 {
entry:
  %0 = trunc i32 %c to i8
  tail call void @llvm.memset.p0i8.i64(i8* %dst, i8 %0, i64 %n, i32 1, i1 false)
  ret i8* %dst

; IR-LABEL:   @memset_caller
; IR:         [[VAL:%[0-9]+]] = trunc i32 %c to i8
; IR:         loadstoreloop:
; IR:         [[STOREPTR:%[0-9]+]] = getelementptr inbounds i8, i8* %dst, i64
; IR-NEXT:    store i8 [[VAL]], i8* [[STOREPTR]]

; PTX-LABEL:  .visible .func (.param .b64 func_retval0) memset_caller(
; PTX:        ld.param.u8 %rs[[REG:[0-9]+]]
; PTX:        LBB[[LABEL:[_0-9]+]]:
; PTX:        st.u8 [%rd{{[0-9]+}}], %rs[[REG]]
; PTX:        add.s64 %rd[[COUNTER:[0-9]+]], %rd[[COUNTER]], 1
; PTX-NEXT:   setp.lt.u64 %p[[PRED:[0-9]+]], %rd[[COUNTER]], %rd
; PTX-NEXT:   @%p[[PRED]] bra LBB[[LABEL]]
}

define i8* @memmove_caller(i8* %dst, i8* %src, i64 %n) #0 {
entry:
  tail call void @llvm.memmove.p0i8.p0i8.i64(i8* %dst, i8* %src, i64 %n, i32 1, i1 false)
  ret i8* %dst

; IR-LABEL:   @memmove_caller
; IR:         icmp ult i8* %src, %dst
; IR:         [[PHIVAL:%[0-9a-zA-Z_]+]] = phi i64
; IR-NEXT:    %index_ptr = sub i64 [[PHIVAL]], 1
; IR:         [[FWDPHIVAL:%[0-9a-zA-Z_]+]] = phi i64
; IR:         {{%[0-9a-zA-Z_]+}} = add i64 [[FWDPHIVAL]], 1

; PTX-LABEL:  .visible .func (.param .b64 func_retval0) memmove_caller(
; PTX:        ld.param.u64 %rd[[N:[0-9]+]]
; PTX:        setp.eq.s64 %p[[NEQ0:[0-9]+]], %rd[[N]], 0
; PTX:        setp.ge.u64 %p[[SRC_GT_THAN_DST:[0-9]+]], %rd{{[0-9]+}}, %rd{{[0-9]+}}
; PTX-NEXT:   @%p[[SRC_GT_THAN_DST]] bra LBB[[FORWARD_BB:[0-9_]+]]
; -- this is the backwards copying BB
; PTX:        @%p[[NEQ0]] bra LBB[[EXIT:[0-9_]+]]
; PTX:        add.s64 %rd[[N]], %rd[[N]], -1
; PTX:        ld.u8 %rs[[ELEMENT:[0-9]+]]
; PTX:        st.u8 [%rd{{[0-9]+}}], %rs[[ELEMENT]]
; -- this is the forwards copying BB
; PTX:        LBB[[FORWARD_BB]]:
; PTX:        @%p[[NEQ0]] bra LBB[[EXIT]]
; PTX:        ld.u8 %rs[[ELEMENT2:[0-9]+]]
; PTX:        st.u8 [%rd{{[0-9]+}}], %rs[[ELEMENT2]]
; PTX:        add.s64 %rd[[INDEX:[0-9]+]], %rd[[INDEX]], 1
; -- exit block
; PTX:        LBB[[EXIT]]:
; PTX-NEXT:   st.param.b64 [func_retval0
; PTX-NEXT:   ret
}
