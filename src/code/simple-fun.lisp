;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;;; Generalizing over SIMPLE-FUN, CLOSURE, and FUNCALLABLE-INSTANCEs

;;; Underlying SIMPLE-FUN
(defun %fun-fun (function)
  (declare (function function))
  ;; It's too bad that TYPECASE isn't able to generate equivalent code.
  (case (fun-subtype function)
    (#.sb!vm:closure-widetag
     (%closure-fun function))
    (#.sb!vm:funcallable-instance-widetag
     ;; %FUNCALLABLE-INSTANCE-FUNCTION is not known to return a FUNCTION.
     ;; Is that right? Shouldn't we always initialize to something
     ;; that is a function, such as an error-signaling trampoline?
     (%fun-fun (%funcallable-instance-function function)))
    (t function)))

(define-load-time-global **closure-names**
    (make-hash-table :test 'eq :weakness :key :synchronized t))

(macrolet ((namedp-bit () #x800000)
           (%closure-index-set (closure index val)
             ;; Use the identical convention as %CLOSURE-INDEX-REF for the index.
             ;; There are no closure slot setters, and in fact SLOT-SET
             ;; does not exist in a variant that takes a non-constant index.
             `(setf (sap-ref-lispobj (int-sap (get-lisp-obj-address ,closure))
                                     (+ (ash sb!vm:closure-info-offset sb!vm:word-shift)
                                        (ash ,index sb!vm:word-shift)
                                        (- sb!vm:fun-pointer-lowtag)))
                    ,val))
           (closure-header-word (closure)
             `(sap-ref-word (int-sap (get-lisp-obj-address ,closure))
                            (- sb!vm:fun-pointer-lowtag))))

  ;;; Assign CLOSURE a NEW-NAME and return the closure (NOT the new name!).
  ;;; If PERMIT-COPY is true, this function may return a copy of CLOSURE
  ;;; to avoid using a global hashtable. We prefer to store the name in the
  ;;; closure itself, which is possible in two cases:
  ;;; (1) if the closure has a padding slot due to alignment constraints,
  ;;;     the padding slot holds the name.
  ;;; (2) if it doesn't, but the caller does not care about identity,
  ;;;     then a copy of the closure with extra slots reduces to case (1).
  (defun set-closure-name (closure permit-copy new-name)
    (declare (closure closure))
    (let ((payload-len (get-closure-length (truly-the function closure)))
          (namedp (logtest (with-pinned-objects (closure)
                             (closure-header-word closure))
                           (namedp-bit))))
      (when (and (not namedp) permit-copy (oddp payload-len))
        ;; PAYLOAD-LEN includes the trampoline, so the number of slots we would
        ;; pass to %COPY-CLOSURE is 1 less than that, were it not for
        ;; the fact that we actually want to create 1 additional slot.
        ;; So in effect, asking for PAYLOAD-LEN does exactly the right thing.
        (let ((copy #!-(or x86 x86-64)
                    (sb!vm::%copy-closure payload-len (%closure-fun closure))
                    #!+(or x86 x86-64)
                    (with-pinned-objects ((%closure-fun closure))
                      ;; %CLOSURE-CALLEE manifests as a fixnum which remains
                      ;; valid across GC due to %CLOSURE-FUN being pinned
                      ;; until after the new closure is made.
                      (sb!vm::%copy-closure payload-len
                                            (sb!vm::%closure-callee closure)))))
          (with-pinned-objects (copy)
            (loop with sap = (int-sap (get-lisp-obj-address copy))
                  for i from 0 below (1- payload-len)
                  for ofs from (- (ash 2 sb!vm:word-shift) sb!vm:fun-pointer-lowtag)
                  by sb!vm:n-word-bytes
                  do (setf (sap-ref-lispobj sap ofs) (%closure-index-ref closure i)))
            (setf (closure-header-word copy) ; Update the header
                  ;; Closure copy lost its high header bits, so OR them in again.
                  (logior #!+(and immobile-space 64-bit sb-thread)
                          (sap-int (sb!vm::current-thread-offset-sap
                                    sb!vm::thread-function-layout-slot))
                          #!+(and immobile-space 64-bit (not sb-thread))
                          (get-lisp-obj-address sb!vm:function-layout)
                          (namedp-bit)
                          (closure-header-word copy)))
            ;; We copy only if there was no padding, which means that adding 1 slot
            ;; physically added 2 slots. You might think that the name goes in the
            ;; first new slot, followed by padding. Nope! Take an example of a
            ;; closure header specifying 3 words, which we increase to 4 words,
            ;; which is 5 with the header, which is 6 aligned to a doubleword:
            ;;   word 0: 2030008300800435
            ;;   word 1: 0000001001A0B280             ] words the closure's fun
            ;;   word 2: 00000000203AA39F = #<thing1> ] "should" use given
            ;;   word 3: 00000000203AA51F = #<thing2> ] 4 payload slots.
            ;;   word 4: 0000000000000000 = 0         ]
            ;;   word 5: 00000010019E2B9F = NAME    <-- name goes here
            ;; This makes CLOSURE-NAME consistent (which is to say, work at all).
            (%closure-index-set copy payload-len new-name)
            (return-from set-closure-name copy))))
      (unless (with-pinned-objects (closure)
                (unless namedp ; Set the header bit
                  (setf (closure-header-word closure)
                        (logior (namedp-bit) (closure-header-word closure))))
                (when (evenp payload-len)
                  (%closure-index-set closure (1- payload-len) new-name)
                  t))
        (setf (gethash closure **closure-names**) new-name)))
    closure)

  ;;; Access the name of CLOSURE. Secondary value is whether it had a name.
  ;;; Following the convention established by SET-CLOSURE-NAME,
  ;;; an even-length payload takes the last slot for the name,
  ;;; and an odd-length payload uses the global hashtable.
  (defun closure-name (closure)
    (declare (closure closure))
    (with-pinned-objects (closure)
      (if (not (logtest (closure-header-word closure) (namedp-bit)))
          (values nil nil)
          ;; CLOSUREP doesn't imply FUNCTIONP, so GET-CLOSURE-LENGTH
          ;; issues an additional check. Silly.
          (let ((len (get-closure-length (truly-the function closure))))
            ;; GET-CLOSURE-LENGTH counts the 'fun' slot in the length,
            ;; but %CLOSURE-INDEX-REF starts indexing from the value slots.
            (if (oddp len)
                (gethash closure **closure-names**) ; returns name and T
                (values (%closure-index-ref closure (1- len)) t)))))))

;;; a SETFable function to return the associated debug name for FUN
;;; (i.e., the third value returned from CL:FUNCTION-LAMBDA-EXPRESSION),
;;; or NIL if there's none
(defun %fun-name (function)
  (case (fun-subtype function)
    (#.sb!vm:closure-widetag
     (multiple-value-bind (name namedp) (closure-name (truly-the closure function))
       (when namedp
         (return-from %fun-name name))))
    (#.sb!vm:funcallable-instance-widetag
     (typecase (truly-the funcallable-instance function)
       (generic-function
        (return-from %fun-name
          (sb!mop:generic-function-name function)))
       #!+sb-eval
       (sb!eval:interpreted-function
        (return-from %fun-name (sb!eval:interpreted-function-debug-name function)))
       #!+sb-fasteval
       (sb!interpreter:interpreted-function
        (return-from %fun-name
          (let ((name (sb!interpreter:proto-fn-name (sb!interpreter:fun-proto-fn function))))
            (unless (eql name 0)
              name)))))))
  (%simple-fun-name (%fun-fun function)))

(defun (setf %fun-name) (new-value function)
  (case (fun-subtype function)
    (#.sb!vm:closure-widetag
     (set-closure-name (truly-the closure function) nil new-value))
    (#.sb!vm:simple-fun-widetag
     (setf (%simple-fun-name function) new-value))
    (t
     (typecase (truly-the funcallable-instance function)
       (generic-function
        (setf (sb!mop:generic-function-name function) new-value))
       #!+sb-eval
       (sb!eval:interpreted-function
        (setf (sb!eval:interpreted-function-debug-name function) new-value))
       #!+sb-fasteval
       (sb!interpreter:interpreted-function
        (setf (sb!interpreter:proto-fn-name (sb!interpreter:fun-proto-fn function))
              new-value)))))
  new-value)

(defun %fun-lambda-list (function)
  (typecase function
    #!+sb-fasteval
    (sb!interpreter:interpreted-function
     (sb!interpreter:proto-fn-pretty-arglist
      (sb!interpreter:fun-proto-fn function)))
    #!+sb-eval
    (sb!eval:interpreted-function
     (sb!eval:interpreted-function-debug-lambda-list function))
    (t
     (%simple-fun-arglist (%fun-fun function)))))

(defun (setf %fun-lambda-list) (new-value function)
  (typecase function
    #!+sb-fasteval
    (sb!interpreter:interpreted-function
     (setf (sb!interpreter:proto-fn-pretty-arglist
            (sb!interpreter:fun-proto-fn function)) new-value))
    #!+sb-eval
    (sb!eval:interpreted-function
     (setf (sb!eval:interpreted-function-debug-lambda-list function) new-value))
    ;; FIXME: Eliding general funcallable-instances for now.
    ((or simple-fun closure)
     (setf (%simple-fun-arglist (%fun-fun function)) new-value)))
  new-value)

;;; Extract the type from the function header FUNC.
(defun %simple-fun-type (func)
  (let ((internal-type (sb!vm::%%simple-fun-type func)))
    ;; For backward-compatibility we expand SFUNCTION -> FUNCTION.
    (if (and (listp internal-type) (eq (car internal-type) 'sfunction))
        (sb!ext:typexpand-1 internal-type)
        internal-type)))

(defun %fun-type (function)
  (typecase function
    #!+sb-fasteval
    ;; Obtain a list of the right shape, usually with T for each
    ;; arg type, but respecting local declarations if any.
    (sb!interpreter:interpreted-function (sb!interpreter:%fun-type function))
    (t (%simple-fun-type (%fun-fun function)))))

;;; A FUN-SRC structure appears in %SIMPLE-FUN-INFO of any function for
;;; which a source form is retained via COMPILE or LOAD and for which it was
;;; required to store all three of these pieces of data.
(defstruct (fun-src (:constructor make-fun-src (form doc xrefs))
                    (:predicate nil)
                    (:copier nil))
  form
  doc
  xrefs)
;;; Assign %SIMPLE-FUN-INFO given the three possible things that
;;; we stash there.
(defun set-simple-fun-info (fun form doc xrefs)
  (setf (%simple-fun-info fun)
        (if form
            ;; If form starts with a string, we can't store it by itself
            ;; because it's confusable with (CONS STRING *)
            ;; Lambda expressions start with LAMBDA, obviously,
            ;; so this really shouldn't happen. Just being defensive here.
            (if (or doc xrefs (typep form '(cons string)))
                (make-fun-src form doc xrefs)
                form)
            (if (and doc xrefs)
                (cons doc xrefs)
                (or doc xrefs)))))

;;; Define readers for parts of SIMPLE-FUN-INFO, which holds:
;;;  - a string if documentation only,
;;;  - a SIMPLE-VECTOR if xrefs only
;;;  - a (CONS STRING SIMPLE-VECTOR) if both
;;;  - a CONS headed by LAMBDA if a source form only
;;;  - a FUN-SRC if other combinations of the above
;;;  - or NIL
(macrolet ((def (name info-part if-simple-vector if-string if-struct)
             `(defun ,name (simple-fun)
                (declare (simple-fun simple-fun))
                (let ((info (%simple-fun-info simple-fun)))
                  (typecase info
                    ;; (CONS (NOT STRING)) implies neither doc nor xref present
                    (list (if (stringp (car info)) (,info-part info)))
                    (simple-vector ,if-simple-vector)
                    (string ,if-string)
                    (fun-src ,if-struct)
                    (t (bug "bogus INFO for ~S: ~S" simple-fun info)))))))
  (def %simple-fun-doc   car nil info (fun-src-doc info))
  (def %simple-fun-xrefs cdr info nil (fun-src-xrefs info)))

;;; Return the lambda expression for SIMPLE-FUN if compiled to memory
;;; and rentention of forms was enabled via the EVAL-STORE-SOURCE-FORM policy
;;; (as is the default).
(defun %simple-fun-lexpr (simple-fun)
  (declare (simple-fun simple-fun))
  (let ((info (%simple-fun-info simple-fun)))
    (typecase info
      (fun-src (fun-src-form info))
      ((cons (not string)) info))))

(defun (setf %simple-fun-doc) (doc simple-fun)
  (declare (type (or null string) doc)
           (simple-fun simple-fun))
  (let ((info (%simple-fun-info simple-fun)))
    (setf (%simple-fun-info simple-fun)
          (typecase info
            ((or null string) doc)
            (simple-vector
             (if doc (cons doc info) info))
            ((cons string)
             (if doc (rplaca info doc) (cdr info)))
            (fun-src
             (setf (fun-src-doc info) doc)
             info)
            ((cons (not string))
             (if doc (make-fun-src info doc nil) info))
            (t
             (bug "bogus INFO for ~S: ~S" simple-fun info)))))
  doc)

(defun %fun-doc (function)
  (typecase function
    #!+sb-fasteval
    (sb!interpreter:interpreted-function
     (sb!interpreter:proto-fn-docstring (sb!interpreter:fun-proto-fn function)))
    #!+sb-eval
    (sb!eval:interpreted-function
     (sb!eval:interpreted-function-documentation function))
    (t
     (when (closurep function)
       (multiple-value-bind (name namedp) (closure-name function)
         (when namedp
           (return-from %fun-doc (random-documentation name 'function)))))
     (%simple-fun-doc (%fun-fun function)))))

(defun (setf %fun-doc) (new-value function)
  (declare (type (or null string) new-value))
  (typecase function
    #!+sb-fasteval
    (sb!interpreter:interpreted-function
     (setf (sb!interpreter:proto-fn-docstring
            (sb!interpreter:fun-proto-fn function)) new-value))
    #!+sb-eval
    (sb!eval:interpreted-function
     (setf (sb!eval:interpreted-function-documentation function) new-value))
    ((or simple-fun closure)
     (when (closurep function)
       (multiple-value-bind (name namedp) (closure-name function)
         (when namedp
           (return-from %fun-doc
             (setf (random-documentation name 'function) new-value)))))
     (setf (%simple-fun-doc (%fun-fun function)) new-value)))
  new-value)

(defun %simple-fun-next (simple-fun) ; DO NOT USE IN NEW CODE
  (let ((code-obj (fun-code-header simple-fun)))
    (dotimes (i (code-n-entries code-obj))
      (when (eq simple-fun (%code-entry-point code-obj i))
        (return (%code-entry-point code-obj (1+ i)))))))

;;;; CODE-COMPONENT

(declaim (inline code-header-words))
(defun code-header-words (code)
  (logand (get-header-data code) sb!vm:short-header-max-words))

(defun %code-entry-points (code-obj) ; DO NOT USE IN NEW CODE
  (%code-entry-point code-obj 0))

(defun code-n-entries (code-obj)
  ;; The internal %n-entries slot is a fixnum storing the number
  ;; of simple-funs in the low 14 bits (16 bits of the machine word),
  ;; and the first function's offset in the high 16 bits.
  #!-64-bit (ldb (byte 14 0) (sb!vm::%code-n-entries code-obj))
  ;; The header stores the count.
  #!+64-bit (ldb (byte 16 24) (get-header-data code-obj)))

(defun %code-entry-point (code-obj fun-index)
  (declare (type (unsigned-byte 16) fun-index))
  (if (>= fun-index (code-n-entries code-obj))
      nil
      (%primitive sb!c:compute-fun
                  code-obj
                  (cond ((zerop fun-index) ; special case for the first simple-fun
                         #!-64-bit (ldb (byte 16 14) (sb!vm::%code-n-entries code-obj))
                         #!+64-bit (ldb (byte 16 40) (get-header-data code-obj)))
                        (t
                         (let ((i (+ (- sb!vm:other-pointer-lowtag)
                                     (ash (code-header-words code-obj)
                                          sb!vm:word-shift)
                                     (ash (1- fun-index) 2))))
                           (with-pinned-objects (code-obj)
                            (sap-ref-32 (int-sap (get-lisp-obj-address code-obj))
                                        i))))))))

(defun code-entry-points (code-obj) ; FIXME: obsolete
  (let ((a (make-array (code-n-entries code-obj))))
    (dotimes (i (length a) a)
      (setf (aref a i) (%code-entry-point code-obj i)))))

(defun code-n-unboxed-data-words (code-obj)
  ;; If the number of boxed words (from the header) is not the same as
  ;; the displacement backwards from the first simple-fun to the header,
  ;; then there are unboxed constants between the end of the boxed constants
  ;; and the first simple-fun.
  (let ((f (%code-entry-point code-obj 0)))
    (or (and f
             (let ((from (code-header-words code-obj))
                   ;; Ignore the layout pointer (if present) in the upper bits
                   ;; of the function header.
                   (to (ldb (byte 24 sb!vm:n-widetag-bits)
                            (with-pinned-objects (f)
                              (sap-ref-word (int-sap (get-lisp-obj-address f))
                                            (- sb!vm:fun-pointer-lowtag))))))
               (and (< from to) (- to from))))
        0)))

;;; Set (SYMBOL-FUNCTION SYMBOL) to a closure that signals an error,
;;; preventing funcall/apply of macros and special operators.
(defun sb!c::install-guard-function (symbol fun-name docstring)
  (when docstring
    (setf (random-documentation symbol 'function) docstring))
  ;; (SETF SYMBOL-FUNCTION) goes out of its way to disallow this closure,
  ;; but we can trivially replicate its low-level effect.
  (let ((fdefn (find-or-create-fdefn symbol))
        (closure
         (set-closure-name
          (lambda (&rest args)
           (declare (ignore args))
           ;; ANSI specification of FUNCALL says that this should be
           ;; an error of type UNDEFINED-FUNCTION, not just SIMPLE-ERROR.
           ;; SPECIAL-FORM-FUNCTION is a subtype of UNDEFINED-FUNCTION.
           (error (if (eq (info :function :kind symbol) :special-form)
                      'special-form-function
                      'undefined-function)
                  :name symbol))
          t
          fun-name)))
    ;; For immobile-code, do something slightly different: fmakunbound,
    ;; then assign the fdefn-fun slot to avoid consing a new closure trampoline.
    #!+immobile-code
    (progn (fdefn-makunbound fdefn)
           ;; There is no :SET-TRANS for the primitive object's fdefn-fun slot,
           ;; nor do we desire the full effect of %SET-FDEFN-FUN.
           (setf (sap-ref-lispobj (int-sap (get-lisp-obj-address fdefn))
                                  (- (ash sb!vm:fdefn-fun-slot sb!vm:word-shift)
                                     sb!vm:other-pointer-lowtag))
                 closure))
    ;; The above would work, but there's no overhead when installing a closure
    ;; the regular way, so just do that.
    #!-immobile-code
    (setf (fdefn-fun fdefn) closure)))

;;;; Iterating over closure values

(defmacro do-closure-values ((value closure) &body body)
  (with-unique-names (i nclosure)
    `(let ((,nclosure ,closure))
       (declare (closure ,nclosure))
       (dotimes (,i (- (1+ (get-closure-length ,nclosure)) sb!vm:closure-info-offset))
         (let ((,value (%closure-index-ref ,nclosure ,i)))
           ,@body)))))

(defun %closure-values (closure)
  (declare (closure closure))
  (let (values)
    (do-closure-values (elt closure)
      (push elt values))
    values)) ; no need to reverse - this has no promised iteration order

;;; This is like FIND-IF, except that we do it on a compiled closure's
;;; environment.
(defun find-if-in-closure (test closure)
  (declare (closure closure))
  (do-closure-values (value closure)
    (when (funcall test value)
      (return value))))

(in-package "SB!C")

;;; This is target-only code, so doesn't belong in 'debug-info.lisp'
(flet ((unpack-tlf-num+offset (integer &aux (bytepos 0))
         (flet ((unpack-1 ()
                  (let ((shift 0) (acc 0))
                    (declare (notinline sb!kernel:%ldb)) ; lp#1573398
                    (loop
                     (let ((byte (ldb (byte 8 bytepos) integer)))
                       (incf bytepos 8)
                       (setf acc (logior acc (ash (logand byte #x7f) shift)))
                       (if (logtest byte #x80)
                           (incf shift 7)
                           (return acc)))))))
           (let ((v1 (unpack-1))
                 (v2 (unpack-1)))
             (values (if (eql v1 0) nil (1- v1))
                     (if (eql v2 0) nil (1- v2)))))))
  (defun compiled-debug-info-tlf-number (cdi)
    (nth-value 0 (unpack-tlf-num+offset
                  (compiled-debug-info-tlf-num+offset cdi))))

  (defun compiled-debug-info-char-offset (cdi)
    (nth-value 1 (unpack-tlf-num+offset
                  (compiled-debug-info-tlf-num+offset cdi)))))
