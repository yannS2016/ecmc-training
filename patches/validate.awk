/^@@/ {
  if (h) check()
  h=1; file=cur
  match($0, /-[0-9]+,?[0-9]*/); a=substr($0,RSTART+1,RLENGTH-1)
  match($0, /\+[0-9]+,?[0-9]*/); b=substr($0,RSTART+1,RLENGTH-1)
  split(a,A,","); split(b,B,",")
  wo=(2 in A)?A[2]:1; wn=(2 in B)?B[2]:1
  go=0; gn=0; hdr=$0; next
}
/^diff --git/ { if (h) check(); h=0; cur=$3; sub(/^a\//,"",cur); next }
h && /^ /  { go++; gn++; next }
h && /^-/  { go++; next }
h && /^\+/ { gn++; next }
h && /^$/  { bad++; printf "  %s: BARE BLANK line in %s\n", FILENAME, hdr }
function check() {
  if (go!=wo || gn!=wn) {
    printf "  %s %s -> declared %d/%d, counted %d/%d  MISMATCH\n", FILENAME, hdr, wo, wn, go, gn
    bad++
  } else printf "  %s %s -> %d/%d ok\n", FILENAME, hdr, go, gn
}
END { if (h) check(); exit (bad>0) }
