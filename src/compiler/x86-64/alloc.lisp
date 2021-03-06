;;;; allocation VOPs for the x86-64

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;;; allocation helpers

;;; Most allocation is done by inline code with sometimes help
;;; from the C alloc() function by way of the alloc-tramp
;;; assembly routine.

(defun allocation-dynamic-extent (alloc-tn size lowtag)
  (aver (not (location= alloc-tn rsp-tn)))
  (inst sub rsp-tn size)
  ;; see comment in x86/macros.lisp implementation of this
  ;; However that comment seems inapplicable here because:
  ;; - PAD-DATA-BLOCK quite clearly enforces double-word alignment,
  ;;   contradicting "... unfortunately not enforced by ..."
  ;; - It's not the job of FIXED-ALLOC to realign anything.
  ;; - The real issue is that it's not obvious that the stack is
  ;;   16-byte-aligned at *all* times. Maybe it is, maybe it isn't.
  (inst and rsp-tn #.(lognot lowtag-mask))
  (inst lea alloc-tn (make-ea :byte :base rsp-tn :disp lowtag))
  (values))

(defun allocation-tramp (node result-tn size lowtag)
  (cond ((typep size '(and integer (not (signed-byte 32))))
         ;; MOV accepts large immediate operands, PUSH does not
         (inst mov result-tn size)
         (inst push result-tn))
        (t
         (inst push size)))
  ;; This really would be better if it recognized TEMP-REG-TN as the "good" case
  ;; rather than specializing on R11, which just happens to be the temp reg.
  ;; But the assembly routine is hand-written, not generated, and it has to match,
  ;; so there's not much that can be done to generalize it.
  (let ((to-r11 (location= result-tn r11-tn)))
    (invoke-asm-routine 'call (if to-r11 'alloc-tramp-r11 'alloc-tramp) node)
    (unless to-r11
      (inst pop result-tn)))

  (when lowtag
    (inst or (reg-in-size result-tn :byte) lowtag))
  (values))

;;; Emit code to allocate an object with a size in bytes given by
;;; SIZE into ALLOC-TN. The size may be an integer of a TN.
;;; NODE may be used to make policy-based decisions.
;;; This function should only be used inside a pseudo-atomic section,
;;; which to the degree needed should also cover subsequent initialization.
(defun allocation (alloc-tn size node &optional dynamic-extent lowtag)
  (when dynamic-extent
    (allocation-dynamic-extent alloc-tn size lowtag)
    (return-from allocation (values)))
  (aver (and (not (location= alloc-tn temp-reg-tn))
             (or (integerp size) (not (location= size temp-reg-tn)))))

  #!+(and (not sb-thread) sb-dynamic-core)
  ;; We'd need a spare reg in which to load boxed_region from the linkage table.
  ;; Could push/pop any random register on the stack and own it temporarily,
  ;; but seeing as nobody cared about this, just punt.
  (allocation-tramp node alloc-tn size lowtag)

  #!-(and (not sb-thread) sb-dynamic-core)
  ;; Otherwise do the normal inline allocation thing
  (let ((NOT-INLINE (gen-label))
        (DONE (gen-label))
        (SKIP-INSTRUMENTATION (gen-label))
        ;; Yuck.
        (in-elsewhere (eq *elsewhere* sb!assem::**current-segment**))
        ;; thread->alloc_region.free_pointer
        (free-pointer
         #!+sb-thread
         (thread-tls-ea (* n-word-bytes thread-alloc-region-slot))
         #!-sb-thread
         (make-ea :qword :disp (make-fixup "gc_alloc_region" :foreign)))
        ;; thread->alloc_region.end_addr
        (end-addr
         #!+sb-thread
         (thread-tls-ea (* n-word-bytes (1+ thread-alloc-region-slot)))
         #!-sb-thread
         (make-ea :qword :disp (make-fixup "gc_alloc_region" :foreign 8))))

    ;; Insert allocation profiler instrumentation
    ;; FIXME: for now, change this to '>=' to perform self-build
    ;;        where the resulting executable has instrumentation
    ;;        because I can't get policies to work.
    ;; FIXME: and does this work for assembly routines?
    (when (policy node (> sb!c::instrument-consing 1))
      (inst mov temp-reg-tn
            (make-ea :qword :base thread-base-tn
                     :disp (* n-word-bytes thread-profile-data-slot)))
      (inst test temp-reg-tn temp-reg-tn)
      ;; This instruction is modified to "JMP :z" when profiling is
      ;; partially enabled. After the buffer is assigned, it becomes
      ;; fully enabled. The unconditional jmp gives minimal performance
      ;; loss if the profiler is statically disabled. (one memory
      ;; read and a test whose result is never used, which the CPU
      ;; is good at ignoring as far as instruction prefetch goes)
      (inst jmp skip-instrumentation)
      (emit-alignment 3 :long-nop)
      (let ((helper (if (integerp size)
                        'enable-alloc-counter
                        'enable-sized-alloc-counter)))
        (cond ((or (not node) ; assembly routine
                   (sb!c::code-immobile-p node))
               (inst call (make-fixup helper :assembly-routine)) ; 5 bytes
               (emit-long-nop sb!assem::**current-segment** 3)) ; align
              (t
               (inst call ; 7 bytes
                     (make-ea :qword :disp
                              (make-fixup helper :assembly-routine*)))
               (inst nop))) ; align
        (unless (integerp size)
          ;; This TEST instruction is never executed- it informs the profiler
          ;; which register holds SIZE.
          (inst test size size) ; 3 bytes
          (emit-long-nop sb!assem::**current-segment** 5))) ; align
      (emit-label skip-instrumentation))

    (cond ((or in-elsewhere
               ;; large objects will never be made in a per-thread region
               (and (integerp size)
                    (>= size large-object-size)))
           (allocation-tramp node alloc-tn size lowtag))
          (t
           (inst mov temp-reg-tn free-pointer)
           (cond ((integerp size)
                  (inst lea alloc-tn (make-ea :qword :base temp-reg-tn :disp size)))
                 ((location= alloc-tn size)
                  (inst add alloc-tn temp-reg-tn))
                 (t
                  (inst lea alloc-tn (make-ea :qword :base temp-reg-tn :index size))))
           (inst cmp alloc-tn end-addr)
           (inst jmp :a NOT-INLINE)
           (inst mov free-pointer alloc-tn)
           (emit-label DONE)
           (if lowtag
               (inst lea alloc-tn (make-ea :byte :base temp-reg-tn :disp lowtag))
               (inst mov alloc-tn temp-reg-tn))
           (assemble (*elsewhere*)
             (emit-label NOT-INLINE)
             (cond ((and (tn-p size) (location= size alloc-tn)) ; recover SIZE
                    (inst sub alloc-tn free-pointer)
                    (allocation-tramp node temp-reg-tn alloc-tn nil))
                   (t ; SIZE is intact
                    (allocation-tramp node temp-reg-tn size nil)))
             (inst jmp DONE))))
    (values)))

;;; Allocate an other-pointer object of fixed SIZE with a single word
;;; header having the specified WIDETAG value. The result is placed in
;;; RESULT-TN.
(defun fixed-alloc (result-tn widetag size node &optional stack-allocate-p)
  (maybe-pseudo-atomic stack-allocate-p
      (allocation result-tn (pad-data-block size) node stack-allocate-p
                  other-pointer-lowtag)
      (storew* (logior (ash (1- size) n-widetag-bits) widetag)
               result-tn 0 other-pointer-lowtag
               (not stack-allocate-p))))

;;;; CONS, LIST and LIST*
(define-vop (list-or-list*)
  (:args (things :more t))
  (:temporary (:sc unsigned-reg) ptr temp)
  (:temporary (:sc unsigned-reg :to (:result 0) :target result) res)
  (:info num)
  (:results (result :scs (descriptor-reg)))
  (:variant-vars star)
  (:policy :safe)
  (:node-var node)
  (:generator 0
    (cond ((zerop num)
           ;; (move result nil-value)
           (inst mov result nil-value))
          ((and star (= num 1))
           (move result (tn-ref-tn things)))
          (t
           (macrolet
               ((store-car (tn list &optional (slot cons-car-slot))
                  `(let ((reg
                          (sc-case ,tn
                            ((any-reg descriptor-reg) ,tn)
                            ((control-stack)
                             (move temp ,tn)
                             temp))))
                     (storew reg ,list ,slot list-pointer-lowtag))))
             (let ((cons-cells (if star (1- num) num))
                   (stack-allocate-p (node-stack-allocate-p node)))
               (maybe-pseudo-atomic stack-allocate-p
                (allocation res (* (pad-data-block cons-size) cons-cells) node
                            stack-allocate-p list-pointer-lowtag)
                (move ptr res)
                (dotimes (i (1- cons-cells))
                  (store-car (tn-ref-tn things) ptr)
                  (setf things (tn-ref-across things))
                  (inst add ptr (pad-data-block cons-size))
                  (storew ptr ptr (- cons-cdr-slot cons-size)
                          list-pointer-lowtag))
                (store-car (tn-ref-tn things) ptr)
                (cond (star
                       (setf things (tn-ref-across things))
                       (store-car (tn-ref-tn things) ptr cons-cdr-slot))
                      (t
                       (storew nil-value ptr cons-cdr-slot
                               list-pointer-lowtag)))
                (aver (null (tn-ref-across things)))))
             (move result res))))))

(define-vop (list list-or-list*)
  (:variant nil))

(define-vop (list* list-or-list*)
  (:variant t))

;;;; special-purpose inline allocators

;;; Special variant of 'storew' which might have a shorter encoding
;;; when storing to the heap (which starts out zero-filled).
(defun storew* (word object slot lowtag zeroed)
  (if (or (not zeroed) (not (typep word '(signed-byte 32))))
      (storew word object slot lowtag) ; Possibly use temp-reg-tn
      (inst mov
            (make-ea (cond ((typep word '(unsigned-byte 8)) :byte)
                           ((and (not (logtest word #xff))
                                 (typep (ash word -8) '(unsigned-byte 8)))
                            ;; Array lengths 128 to 16384 which are multiples of 128
                            (setq word (ash word -8))
                            (decf lowtag 1) ; increment address by 1
                            :byte)
                           ((and (not (logtest word #xffff))
                                 (typep (ash word -16) '(unsigned-byte 8)))
                            ;; etc
                            (setq word (ash word -16))
                            (decf lowtag 2) ; increment address by 2
                            :byte)
                           ((typep word '(unsigned-byte 16)) :word)
                           ;; Definitely a (signed-byte 32) due to pre-test.
                           (t :dword))
                     :base object
                     :disp (- (* slot n-word-bytes) lowtag))
            word)))

;;; ALLOCATE-VECTOR
(macrolet ((calc-size-in-bytes (n-words result-tn)
             `(cond ((sc-is ,n-words immediate)
                     (pad-data-block (+ (tn-value ,n-words) vector-data-offset)))
                    (t
                     (inst lea ,result-tn
                           (make-ea :byte :index ,n-words
                                          :scale (ash 1 (- word-shift n-fixnum-tag-bits))
                                          :disp (+ lowtag-mask
                                                   (* vector-data-offset n-word-bytes))))
                     (inst and ,result-tn (lognot lowtag-mask))
                     ,result-tn)))
           (put-header (vector-tn type length zeroed)
             `(progn (storew* (if (sc-is ,type immediate) (tn-value ,type) ,type)
                              ,vector-tn 0 other-pointer-lowtag ,zeroed)
                     (storew* (if (sc-is ,length immediate)
                                  (fixnumize (tn-value ,length))
                                  ,length)
                              ,vector-tn vector-length-slot other-pointer-lowtag
                              ,zeroed))))

  (define-vop (allocate-vector-on-heap)
    (:args (type :scs (unsigned-reg immediate))
           (length :scs (any-reg immediate))
           (words :scs (any-reg immediate)))
    ;; Result is live from the beginning, like a temp, because we use it as such
    ;; in 'calc-size-in-bytes'
    (:results (result :scs (descriptor-reg) :from :load))
    (:arg-types positive-fixnum positive-fixnum positive-fixnum)
    (:policy :fast-safe)
    (:node-var node)
    (:generator 100
      ;; The LET generates instructions that needn't be pseudoatomic
      ;; so don't move it inside.
      (let ((size (calc-size-in-bytes words result)))
        (pseudo-atomic
         (allocation result size node nil other-pointer-lowtag)
         (put-header result type length t)))))

  (define-vop (allocate-vector-on-stack)
    (:args (type :scs (unsigned-reg immediate))
           (length :scs (any-reg immediate))
           (words :scs (any-reg immediate)))
    (:results (result :scs (descriptor-reg) :from :load))
    (:temporary (:sc any-reg :offset ecx-offset :from :eval) rcx)
    (:temporary (:sc any-reg :offset eax-offset :from :eval) rax)
    (:temporary (:sc any-reg :offset edi-offset :from :eval) rdi)
    (:temporary (:sc complex-double-reg) zero)
    (:arg-types positive-fixnum positive-fixnum positive-fixnum)
    (:translate allocate-vector)
    (:policy :fast-safe)
    (:node-var node)
    (:generator 100
      (let ((size (calc-size-in-bytes words result))
            (rax-zeroed))
        (allocation result size node t other-pointer-lowtag)
        (put-header result type length nil)
        ;; FIXME: It would be good to check for stack overflow here.
        ;; It would also be good to skip zero-fill of specialized vectors
        ;; perhaps in a policy-dependent way. At worst you'd see random
        ;; bits, and CLHS says consequences are undefined.
        (when sb!c::*msan-unpoison*
          ;; Unpoison all DX vectors regardless of widetag.
          ;; Mark the header and length as valid, not just the payload.
          #!+linux ; unimplemented for others
          (let ((words-savep
                 ;; 'words' might be co-located with any of the temps
                 (or (location= words rdi) (location= words rcx) (location= words rax)))
                (rax rax))
            (setq rax-zeroed (not (location= words rax)))
            (when words-savep ; use 'result' to save 'words'
              (inst mov result words))
            (cond ((sc-is words immediate)
                   (inst mov rcx (+ (tn-value words) vector-data-offset)))
                  (t
                   (inst lea rcx
                         (make-ea :qword :base words
                                  :disp (ash vector-data-offset n-fixnum-tag-bits)))
                   (if (= n-fixnum-tag-bits 1)
                       (setq rax (reg-in-size rax :dword)) ; don't bother shifting rcx
                       (inst shr rcx n-fixnum-tag-bits))))
            (inst mov rdi msan-mem-to-shadow-xor-const)
            (inst xor rdi rsp-tn) ; compute shadow address
            (zeroize rax)
            (inst rep)
            (inst stos rax)
            (when words-savep
              (inst mov words result) ; restore 'words'
              (inst lea result ; recompute the tagged pointer
                    (make-ea :byte :base rsp-tn :disp other-pointer-lowtag)))))
        (let ((data-addr
                (make-ea :qword :base result
                                :disp (- (* vector-data-offset n-word-bytes)
                                         other-pointer-lowtag))))
          (block zero-fill
            (cond ((sc-is words immediate)
                   (let ((n (tn-value words)))
                     (cond ((> n 8)
                            (inst mov rcx (tn-value words)))
                           ((= n 1)
                            (inst mov data-addr 0)
                            (return-from zero-fill))
                           (t
                            (multiple-value-bind (double single) (truncate n 2)
                              (inst xorpd zero zero)
                              (dotimes (i double)
                                (inst movapd data-addr zero)
                                (setf data-addr (copy-structure data-addr))
                                (incf (ea-disp data-addr) (* n-word-bytes 2)))
                              (unless (zerop single)
                                (inst movaps data-addr zero))
                              (return-from zero-fill))))))
                  (t
                   (move rcx words)
                   (inst shr rcx n-fixnum-tag-bits)))
            (inst lea rdi data-addr)
            (unless rax-zeroed (zeroize rax))
            (inst rep)
            (inst stos rax)))))))

;;; ALLOCATE-LIST
(macrolet ((calc-size-in-bytes (length answer)
             `(cond ((sc-is ,length immediate)
                     (aver (/= (tn-value ,length) 0))
                     (* (tn-value ,length) n-word-bytes 2))
                    (t
                     (inst mov result nil-value)
                     (inst test ,length ,length)
                     (inst jmp :z done)
                     (inst lea ,answer
                           (make-ea :byte :base nil :index ,length
                                    :scale (ash 1 (1+ (- word-shift
                                                         n-fixnum-tag-bits)))))
                     ,answer)))
           (compute-end ()
             `(let ((size (cond ((or (not (fixnump size))
                                     (immediate32-p size))
                                 size)
                                (t
                                 (inst mov limit size)
                                 limit))))
                (inst lea limit
                      (make-ea :qword :base result
                                      :index (if (fixnump size) nil size)
                                      :disp (if (fixnump size) size 0))))))

  (define-vop (allocate-list-on-stack)
    (:args (length :scs (any-reg immediate))
           (element :scs (any-reg descriptor-reg)))
    (:results (result :scs (descriptor-reg) :from :load))
    (:arg-types positive-fixnum *)
    (:policy :fast-safe)
    (:node-var node)
    (:temporary (:sc descriptor-reg) tail next limit)
    (:node-var node)
    (:generator 20
      (let ((size (calc-size-in-bytes length next))
            (loop (gen-label)))
        (allocation result size node t list-pointer-lowtag)
        (compute-end)
        (inst mov next result)
        (emit-label LOOP)
        (inst mov tail next)
        (inst add next (* 2 n-word-bytes))
        (storew element tail cons-car-slot list-pointer-lowtag)
        ;; Store the CDR even if it will be smashed to nil.
        (storew next tail cons-cdr-slot list-pointer-lowtag)
        (inst cmp next limit)
        (inst jmp :ne loop)
        (storew nil-value tail cons-cdr-slot list-pointer-lowtag))
      done))

  (define-vop (allocate-list-on-heap)
    (:args (length :scs (any-reg immediate))
           (element :scs (any-reg descriptor-reg)
                    :load-if (not (and (sc-is element immediate)
                                       (eql (tn-value element) 0)))))
    (:results (result :scs (descriptor-reg) :from :load))
    (:arg-types positive-fixnum *)
    (:policy :fast-safe)
    (:node-var node)
    (:temporary (:sc descriptor-reg) tail next limit)
    (:generator 20
      (let ((size (calc-size-in-bytes length next))
            (entry (gen-label))
            (loop (gen-label))
            (no-init
             (and (sc-is element immediate) (eql (tn-value element) 0))))
        (pseudo-atomic
         (allocation result size node nil list-pointer-lowtag)
         (compute-end)
         (inst mov next result)
         (inst jmp entry)
         (emit-label LOOP)
         (storew next tail cons-cdr-slot list-pointer-lowtag)
         (emit-label ENTRY)
         (inst mov tail next)
         (inst add next (* 2 n-word-bytes))
         (unless no-init ; don't bother writing zeros in the CARs
           (storew element tail cons-car-slot list-pointer-lowtag))
         (inst cmp next limit)
         (inst jmp :ne loop))
        (storew nil-value tail cons-cdr-slot list-pointer-lowtag))
      done)))

#!-immobile-space
(define-vop (make-fdefn)
  (:policy :fast-safe)
  (:translate make-fdefn)
  (:args (name :scs (descriptor-reg) :to :eval))
  (:results (result :scs (descriptor-reg) :from :argument))
  (:node-var node)
  (:generator 37
    (fixed-alloc result fdefn-widetag fdefn-size node)
    (storew name result fdefn-name-slot other-pointer-lowtag)
    (storew nil-value result fdefn-fun-slot other-pointer-lowtag)
    (storew (make-fixup 'undefined-tramp :assembly-routine)
            result fdefn-raw-addr-slot other-pointer-lowtag)))

(define-vop (make-closure)
  ; (:args (function :to :save :scs (descriptor-reg)))
  (:info label length stack-allocate-p)
  (:temporary (:sc any-reg) temp)
  (:results (result :scs (descriptor-reg)))
  (:node-var node)
  (:generator 10
   (maybe-pseudo-atomic stack-allocate-p
     (let* ((size (+ length closure-info-offset))
            (header (logior (ash (1- size) n-widetag-bits) closure-widetag)))
       (allocation result (pad-data-block size) node stack-allocate-p
                   fun-pointer-lowtag)
       (storew* #!-immobile-space header ; write the widetag and size
                #!+immobile-space        ; ... plus the layout pointer
                (progn (inst mov temp header)
                       (inst or temp #!-sb-thread (static-symbol-value-ea 'function-layout)
                                     #!+sb-thread
                                     (thread-tls-ea (ash thread-function-layout-slot
                                                         word-shift)))
                       temp)
                result 0 fun-pointer-lowtag (not stack-allocate-p)))
     ;; These two instructions are within the scope of PSEUDO-ATOMIC.
     ;; This is due to scav_closure() assuming that it can always subtract
     ;; FUN_RAW_ADDR_OFFSET from closure->fun to obtain a Lisp object,
     ;; without any precheck for whether that word is currently 0.
     (inst lea (reg-in-size temp :immobile-code-pc) (make-fixup nil :closure label))
     (storew (reg-in-size temp
                          (if stack-allocate-p
                              ;; Need to do a full word store because the stack not zeroed
                              :qword
                              :immobile-code-pc))
             result closure-fun-slot fun-pointer-lowtag))))

;;; The compiler likes to be able to directly make value cells.
(define-vop (make-value-cell)
  (:args (value :scs (descriptor-reg any-reg) :to :result))
  (:results (result :scs (descriptor-reg) :from :eval))
  (:info stack-allocate-p)
  (:node-var node)
  (:generator 10
    (fixed-alloc result value-cell-widetag value-cell-size node stack-allocate-p)
    (storew value result value-cell-value-slot other-pointer-lowtag)))

;;;; automatic allocators for primitive objects

(define-vop (make-unbound-marker)
  (:args)
  (:results (result :scs (descriptor-reg any-reg)))
  (:generator 1
    (inst mov result unbound-marker-widetag)))

(define-vop (make-funcallable-instance-tramp)
  (:args)
  (:results (result :scs (any-reg)))
  (:vop-var vop)
  (:generator 1
    (let ((tramp (make-fixup 'funcallable-instance-tramp :assembly-routine)))
      (if (sb!c::code-immobile-p vop)
          (inst lea result (make-ea :qword :base rip-tn :disp tramp))
          (inst mov result tramp)))))

(define-vop (fixed-alloc)
  (:args)
  (:info name words type lowtag stack-allocate-p)
  (:results (result :scs (descriptor-reg)))
  (:node-var node)
  (:generator 50
    (progn name) ; possibly not used
    (maybe-pseudo-atomic stack-allocate-p
     (allocation result (pad-data-block words) node stack-allocate-p lowtag)
     (when type
       (let* ((widetag (if (typep type 'layout) instance-widetag type))
              (header (logior (ash (1- words) n-widetag-bits) widetag)))
         (if (or #!+compact-instance-header
                 (and (eq name '%make-structure-instance) stack-allocate-p))
             ;; Write a :DWORD, not a :QWORD, because the high half will be
             ;; filled in when the layout is stored. Can't use STOREW* though,
             ;; because it tries to store as few bytes as possible,
             ;; where this instruction must write exactly 4 bytes.
             (inst mov (make-ea :dword :base result :disp (- lowtag)) header)
             (storew* header result 0 lowtag (not stack-allocate-p)))
         (unless (eq type widetag) ; TYPE is actually a LAYOUT
           (inst mov (make-ea :dword :base result :disp (+ 4 (- lowtag)))
                 ;; XXX: should layout fixups use a name, not a layout object?
                 (make-fixup type :layout))))))))

;;; Allocate a non-vector variable-length object.
;;; Exactly 4 allocators are rendered via this vop:
;;;  BIGNUM               (%ALLOCATE-BIGNUM)
;;;  FUNCALLABLE-INSTANCE (%MAKE-FUNCALLABLE-INSTANCE)
;;;  CLOSURE              (%COPY-CLOSURE)
;;;  INSTANCE             (%MAKE-INSTANCE)
;;; WORDS accounts for the mandatory slots *including* the header.
;;; EXTRA is the variable payload, also measured in words.
(define-vop (var-alloc)
  (:args (extra :scs (any-reg)))
  (:arg-types positive-fixnum)
  (:info name words type lowtag)
  (:ignore name)
  (:results (result :scs (descriptor-reg) :from (:eval 1)))
  (:temporary (:sc unsigned-reg :from :eval :to (:eval 1)) bytes)
  (:temporary (:sc unsigned-reg :from :eval :to :result) header)
  (:node-var node)
  (:generator 50
   ;; With the exception of bignums, these objects have effectively
   ;; 32-bit headers because the high half contains other data.
   (multiple-value-bind (bytes header extra)
      (if (= type bignum-widetag)
          (values bytes header extra)
          (values (reg-in-size bytes  :dword)
                  (reg-in-size header :dword)
                  (reg-in-size extra  :dword)))
    (inst lea bytes
          (make-ea :qword :disp (* (1+ words) n-word-bytes) :index extra
                   :scale (ash 1 (- word-shift n-fixnum-tag-bits))))
    (inst mov header bytes)
    (inst shl header (- n-widetag-bits word-shift)) ; w+1 to length field
    (inst lea header                    ; (w-1 << 8) | type
          (make-ea :qword :base header
                   :disp (+ (ash -2 n-widetag-bits) type)))
    (inst and bytes (lognot lowtag-mask)))
    (pseudo-atomic
     (allocation result bytes node nil lowtag)
     (storew header result 0 lowtag))))

#!+immobile-space
(progn
(define-vop (alloc-immobile-fixedobj)
  (:info lowtag size word0 word1)
  (:temporary (:sc unsigned-reg :to :eval :offset rdi-offset) c-arg1)
  (:temporary (:sc unsigned-reg :to :eval :offset rsi-offset) c-arg2)
  (:temporary (:sc unsigned-reg :from :eval :to (:result 0) :offset rax-offset)
              c-result)
  (:results (result :scs (descriptor-reg)))
  (:generator 50
   (inst mov c-arg1 size)
   (inst mov c-arg2 word0)
   ;; RSP needn't be restored because the allocators all return immediately
   ;; which has that effect
   (inst and rsp-tn -16)
   (pseudo-atomic
     (inst call (make-fixup "alloc_fixedobj" :foreign))
     (inst lea result (make-ea :qword :base c-result :disp lowtag))
     ;; If code, the next word must be set within the P-A
     ;; otherwise the GC would compute the wrong object size.
     (when word1
       (inst mov (make-ea :qword :base result :disp (- n-word-bytes lowtag)) word1)))))
(define-vop (alloc-immobile-layout)
  (:args (slots :scs (descriptor-reg) :target c-arg1))
  (:temporary (:sc unsigned-reg :from (:argument 0) :to :eval :offset rdi-offset)
              c-arg1)
  (:temporary (:sc unsigned-reg :from :eval :to (:result 0) :offset rax-offset)
              c-result)
  (:results (result :scs (descriptor-reg)))
  (:generator 50
   (move c-arg1 slots)
   ;; RSP needn't be restored because the allocators all return immediately
   ;; which has that effect
   (inst and rsp-tn -16)
   (pseudo-atomic
     (inst call (make-fixup "alloc_layout" :foreign)))
     (move result c-result)))
) ; end PROGN

