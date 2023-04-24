open Core
module AS = Assem_l4

let mac = true

let get_efkt_name = function
  | AS.Div -> "____JAVAWAY_div"
  | AS.Mod -> "____JAVAWAY_rem"
  | AS.ShiftL -> "____JAVAWAY_shl"
  | AS.ShiftR -> "____JAVAWAY_shr"
;;

let format_mod () =
  "\n; Safe division function\ndefine i32 @"
  ^ get_efkt_name AS.Mod
  ^ "(i32 %a, i32 %b) {\n\
     entry:\n\
    \  ; Check if b is 0\n\
    \  %is_zero = icmp eq i32 %b, 0\n\n\
    \  ; Check if a is INT_MIN and b is -1\n\
    \  %is_int_min = icmp eq i32 %a, -2147483648\n\
    \  %is_minus_one = icmp eq i32 %b, -1\n\
    \  %is_int_min_div_minus_one = and i1 %is_int_min, %is_minus_one\n\n\
    \  ; Combine the two checks\n\
    \  %invalid_division = or i1 %is_zero, %is_int_min_div_minus_one\n\n\
    \  ; If either check is true, call raise(8)\n\
    \  br i1 %invalid_division, label %call_raise, label %continue\n\n\
     call_raise:\n\
    \  call void @raise(i32 8)\n\
    \  unreachable\n\n\
     continue:\n\
     %result = srem i32 %a, %b\n\
     ret i32 %result\n\
     }"
;;

let format_div () =
  "\n; Safe division function\ndefine i32 @"
  ^ get_efkt_name AS.Div
  ^ "(i32 %a, i32 %b) {\n\
     entry:\n\
    \  ; Check if b is 0\n\
    \  %is_zero = icmp eq i32 %b, 0\n\n\
    \  ; Check if a is INT_MIN and b is -1\n\
    \  %is_int_min = icmp eq i32 %a, -2147483648\n\
    \  %is_minus_one = icmp eq i32 %b, -1\n\
    \  %is_int_min_div_minus_one = and i1 %is_int_min, %is_minus_one\n\n\
    \  ; Combine the two checks\n\
    \  %invalid_division = or i1 %is_zero, %is_int_min_div_minus_one\n\n\
    \  ; If either check is true, call raise(8)\n\
    \  br i1 %invalid_division, label %call_raise, label %continue\n\n\
     call_raise:\n\
    \  call void @raise(i32 8)\n\
    \  unreachable\n\n\
     continue:\n\
    \  %result = sdiv i32 %a, %b\n\
    \  ret i32 %result\n\
     }"
;;

let format_shl () =
  "define i32 @"
  ^ get_efkt_name AS.ShiftL
  ^ "(i32 %value, i32 %shift_amount) {\n\
    \  %is_negative = icmp slt i32 %shift_amount, 0\n\
    \  %is_large = icmp ugt i32 %shift_amount, 31\n\
    \  %invalid = or i1 %is_negative, %is_large\n\
    \  br i1 %invalid, label %error, label %valid\n\n\
     error:\n\
    \  ; Raise SIGFPE\n\
    \  call void @raise(i32 8)\n\
    \  unreachable\n\n\
     valid:\n\
    \  %result = shl i32 %value, %shift_amount\n\
    \  ret i32 %result\n\
     }"
;;

let format_shr () =
  "define i32 @"
  ^ get_efkt_name AS.ShiftR
  ^ "(i32 %value, i32 %shift_amount) {\n\
    \  %is_negative = icmp slt i32 %shift_amount, 0\n\
    \  %is_large = icmp ugt i32 %shift_amount, 31\n\
    \  %invalid = or i1 %is_negative, %is_large\n\
    \  br i1 %invalid, label %error, label %valid\n\n\
     error:\n\
    \  ; Raise SIGFPE\n\
    \  call void @raise(i32 8)\n\
    \  unreachable\n\n\
     valid:\n\
    \  %result = ashr i32 %value, %shift_amount\n\
    \  ret i32 %result\n\
     }"
;;

let format_pre () =
  [ ""
  ; "declare dso_local void @raise(i32) #1"
  ; format_div ()
  ; format_mod ()
  ; format_shl ()
  ; format_shr ()
  ]
  |> String.concat ~sep:"\n"
;;

let get_pre (file : string) : string =
  if mac
  then
    sprintf
      "; ModuleID = '%s'\n\
       target datalayout = \"e-m:o-i64:64-i128:128-n32:64-S128\"\n\
       target triple = \"arm64-apple-macosx12.0.0\"\n\
       %s"
      file
      (format_pre ())
  else
    sprintf
      "; ModuleID = '%s'\n\
       source_filename = \"%s\"\n\
       target datalayout = \
       \"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128\"\n\
       target triple = \"x86_64-pc-linux-gnu\"\n\
      \ %s"
      file
      file
      (format_pre ())
;;

let get_post (_ : string) : string =
  if mac
  then
    "\n\
    \  attributes #1 = { nofree norecurse nosync nounwind readnone ssp uwtable \
     \"frame-pointer\"=\"non-leaf\" \"min-legal-vector-width\"=\"0\" \
     \"no-trapping-math\"=\"true\" \"probe-stack\"=\"__chkstk_darwin\" \
     \"stack-protector-buffer-size\"=\"8\" \"target-cpu\"=\"apple-m1\" \
     \"target-features\"=\"+aes,+crc,+crypto,+dotprod,+fp-armv8,+fp16fml,+fullfp16,+lse,+neon,+ras,+rcpc,+rdm,+sha2,+sha3,+sm4,+v8.5a,+zcm,+zcz\" \
     }\n\n\
    \  !llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}\n\
    \  !llvm.ident = !{!9}\n\
    \  \n\
    \  !0 = !{i32 2, !\"SDK Version\", [2 x i32] [i32 12, i32 3]}\n\
    \  !1 = !{i32 1, !\"wchar_size\", i32 4}\n\
    \  !2 = !{i32 1, !\"branch-target-enforcement\", i32 0}\n\
    \  !3 = !{i32 1, !\"sign-return-address\", i32 0}\n\
    \  !4 = !{i32 1, !\"sign-return-address-all\", i32 0}\n\
    \  !5 = !{i32 1, !\"sign-return-address-with-bkey\", i32 0}\n\
    \  !6 = !{i32 7, !\"PIC Level\", i32 2}\n\
    \  !7 = !{i32 7, !\"uwtable\", i32 1}\n\
    \  !8 = !{i32 7, !\"frame-pointer\", i32 1}\n\
    \  !9 = !{!\"Apple clang version 14.0.0 (clang-1400.0.29.102)\"}\n"
  else
    "attributes #0 = { norecurse nounwind readnone uwtable \
     \"correctly-rounded-divide-sqrt-fp-math\"=\"false\" \
     \"disable-tail-calls\"=\"false\" \"frame-pointer\"=\"none\" \
     \"less-precise-fpmad\"=\"false\" \"min-legal-vector-width\"=\"0\" \
     \"no-infs-fp-math\"=\"false\" \"no-jump-tables\"=\"false\" \
     \"no-nans-fp-math\"=\"false\" \"no-signed-zeros-fp-math\"=\"false\" \
     \"no-trapping-math\"=\"false\" \"stack-protector-buffer-size\"=\"8\" \
     \"target-cpu\"=\"x86-64\" \"target-features\"=\"+cx8,+fxsr,+mmx,+sse,+sse2,+x87\" \
     \"unsafe-fp-math\"=\"false\" \"use-soft-float\"=\"false\" }\n\
     attributes #1 = { nounwind }\n\
    \     !llvm.module.flags = !{!0}\n\
     !llvm.ident = !{!1}\n\
     !0 = !{i32 1, !\"wchar_size\", i32 4}\n\
     !1 = !{!\"clang version 10.0.0-4ubuntu1 \"}"
;;
