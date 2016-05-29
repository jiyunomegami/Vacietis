(in-package #:vacietis)

(in-readtable vacietis)

;;(declaim (optimize (debug 3)))
(declaim (optimize (speed 3) (debug 0) (safety 1)))

(in-package #:vacietis.c)

(cl:defparameter vacietis::*type-qualifiers*
  #(static const signed unsigned extern auto register))

(cl:defparameter vacietis::*ops*
  #(= += -= *= /= %= <<= >>= &= ^= |\|=| ? |:| |\|\|| && |\|| ^ & == != < > <= >= << >> ++ -- + - * / % ! ~ -> |.| |,|
    integer/
    truncl ceil))

(cl:defparameter vacietis::*possible-prefix-ops*
  #(! ~ sizeof - + & * ++ --))

(cl:defparameter vacietis::*ambiguous-ops*
  #(- + & *))

(cl:defparameter vacietis::*assignment-ops*
  #(= += -= *= /= %= <<= >>= &= ^= |\|=|
    integer/=))

(cl:defparameter vacietis::*binary-ops-table*
  #((|\|\||)                            ; or
    (&&)                                ; and
    (|\||)                              ; logior
    (^)                                 ; logxor
    (&)                                 ; logand
    (== !=)
    (< > <= >=)
    (<< >>)                             ; ash
    (+ -)
    (* / %)))

(cl:defparameter vacietis::*math*
  #(truncl ceil))

(cl:in-package #:vacietis)

(defvar %in)
(defvar *c-file* nil)
(defvar *line-number*  nil)

;;; a C macro can expand to several statements; READ should return all of them

(defvar *macro-stream*)

;;; error reporting

;; sbcl bug?
#+sbcl
(in-package :sb-c)
#+sbcl
(defun find-source-root (index info)
  (declare (type index index) (type source-info info))
  (let ((file-info (source-info-file-info info)))
    (handler-case
        (values (aref (file-info-forms file-info) index)
                (aref (file-info-positions file-info) index))
      (sb-int:invalid-array-index-error ()
        (format t "invalid array index: ~S  file-info: ~S~%" index file-info)))))
(in-package :vacietis)

(define-condition c-reader-error (reader-error) ;; SBCL hates simple-conditions?
  ((c-file      :reader c-file      :initform *c-file*)
   (line-number :reader line-number :initform *line-number*)
   (msg         :reader msg         :initarg  :msg))
  (:report (lambda (condition stream)
             (write-string (msg condition) stream))))

(defun read-error (msg &rest args)
  (error
   (make-condition
    'c-reader-error
    :stream %in
    :msg (format nil
                 "Error reading C stream~@[ from file ~A~]~@[ at line ~A~]:~% ~?"
                 *c-file* *line-number* msg args))))

;;; basic stream stuff

(defun c-read-char ()
  (let ((c (read-char %in nil)))
    (when (and (eql c #\Newline) *line-number*)
      (incf *line-number*))
    c))

(defun c-unread-char (c)
  (when (and (eql c #\Newline) *line-number*)
    (decf *line-number*))
  (unread-char c %in))

(defmacro loop-reading (&body body)
  `(loop with c do (setf c (c-read-char))
        ,@body))

(defun next-char (&optional (eof-error? t))
  "Returns the next character, skipping over whitespace and comments"
  (loop-reading
     while (case c
             ((nil)                     (when eof-error?
                                          (read-error "Unexpected end of file")))
             (#\/                       (%maybe-read-comment))
             ((#\Space #\Newline #\Tab) t))
     finally (return c)))

(defun make-buffer (&optional (element-type t))
  (make-array 10 :adjustable t :fill-pointer 0 :element-type element-type))

(defun slurp-while (predicate)
  (let ((string-buffer (make-buffer 'character)))
    (loop-reading
       while (and c (funcall predicate c))
       do (vector-push-extend c string-buffer)
       finally (when c (c-unread-char c)))
    string-buffer))

(defun %maybe-read-comment ()
  (case (peek-char nil %in)
    (#\/ (when *line-number* (incf *line-number*))
         (read-line %in))
    (#\* (slurp-while (let ((previous-char (code-char 0)))
                        (lambda (c)
                          (prog1 (not (and (char= previous-char #\*)
                                           (char= c #\/)))
                            (setf previous-char c)))))
         (c-read-char))))

(defun read-c-comment (%in slash)
  (declare (ignore slash))
  (%maybe-read-comment)
  (values))

;;; numbers

(defun read-octal ()
  (parse-integer (slurp-while (lambda (c) (char<= #\0 c #\7)))
                 :radix 8))

(defun read-hex ()
  (parse-integer
   (slurp-while (lambda (c)
                  (or (char<= #\0 c #\9) (char-not-greaterp #\A c #\F))))
   :radix 16))

(defun read-float (prefix separator)
  (let ((*readtable* (find-readtable :common-lisp))
        (*read-default-float-format* 'double-float))
    (read-from-string
     (format nil "~d~a~a" prefix separator
             (slurp-while (lambda (c) (find c "0123456789+-eE" :test #'char=)))))))

(defun read-decimal (c0) ;; c0 must be #\1 to #\9
  (labels ((digit-value (c) (- (char-code c) 48)))
    (let ((value (digit-value c0)))
      (loop-reading
           (cond ((null c)
                  (return value))
                 ((char<= #\0 c #\9)
                  (setf value (+ (* 10 value) (digit-value c))))
                 ((or (char-equal c #\E) (char= c #\.))
                  (return (read-float value c)))
                 (t
                  (c-unread-char c)
                  (return value)))))))

(defun read-c-number (c)
  (prog1 (if (char= c #\0)
             (let ((next (peek-char nil %in)))
               (if (digit-char-p next 8)
                   (read-octal)
                   (case next
                     ((#\X #\x) (c-read-char) (read-hex))
                     (#\.       (c-read-char) (read-float 0 #\.))
                     (otherwise 0))))
             (read-decimal c))
    (loop repeat 2 do (when (find (peek-char nil %in nil nil) "ulf" :test #'eql)
                        (c-read-char)))))

;;; string and chars (caller has to remember to discard leading #\L!!!)

(defun read-char-literal (c)
  (if (char= c #\\)
      (let ((c (c-read-char)))
        (code-char (case c
                     (#\a 7)
                     (#\f 12)
                     (#\n 10)
                     (#\r 13)
                     (#\t 9)
                     (#\v 11)
                     (#\x (read-hex))
                     (otherwise (if (char<= #\0 c #\7)
                                    (progn (c-unread-char c) (read-octal))
                                    (char-code c))))))
      c))

(defun read-character-constant (%in single-quote)
  (declare (ignore single-quote))
  (prog1 (char-code (read-char-literal (c-read-char)))
    (unless (char= (c-read-char) #\')
      (read-error "Junk in character constant"))))

(defun read-c-string (%in double-quotes)
  (declare (ignore double-quotes))
  (let ((string (make-buffer 'character)))
    (loop-reading
       (if (char= c #\") ;; c requires concatenation of adjacent string literals
           (progn (setf c (next-char nil))
                  (unless (eql c #\")
                    (when c (c-unread-char c))
                    (return `(string-to-char* ,string))))
           (vector-push-extend (read-char-literal c) string)))))

;;; preprocessor

(defvar preprocessor-if-stack ())

(defun pp-read-line ()
  (let (comment-follows?)
   (prog1
       (slurp-while (lambda (c)
                      (case c
                        (#\Newline)
                        (#\/ (if (find (peek-char nil %in nil nil) "/*")
                                 (progn (setf comment-follows? t) nil)
                                 t))
                        (t t))))
     (c-read-char)
     (when comment-follows?
       (%maybe-read-comment)))))

(defmacro lookup-define ()
  `(gethash (read-c-identifier (next-char))
            (compiler-state-pp *compiler-state*)))

(defun starts-with? (str x)
  (string= str x :end1 (min (length str) (length x))))

(defun preprocessor-skip-branch ()
  (let ((if-nest-depth 1))
    (loop for line = (pp-read-line) do
         (cond ((starts-with? line "#if")
                (incf if-nest-depth))
               ((and (starts-with? line "#endif")
                     (= 0 (decf if-nest-depth)))
                (pop preprocessor-if-stack)
                (return))
               ((and (starts-with? line "#elif")
                     (= 1 if-nest-depth))
                (case (car preprocessor-if-stack)
                  (if (when (preprocessor-test (pp-read-line))
                        (setf (car preprocessor-if-stack) 'elif)
                        (return)))
                  (elif nil)
                  (else (read-error "Misplaced #elif"))))))))

(defun preprocessor-test (line)
  (let ((exp (with-input-from-string (%in line)
               (read-infix-exp (read-c-exp (next-char))))))
    (dbg "preprocessor-test: ~S~%" exp)
    (eval `(symbol-macrolet
               ,(let ((x))
                     (maphash (lambda (k v)
                                (push (list k v) x))
                              (compiler-state-pp *compiler-state*))
                     x)
             ,exp))))

(defun fill-in-template (args template subs)
  (ppcre:regex-replace-all
   (format nil "([^a-zA-Z])?(~{~a~^|~})([^a-zA-Z0-9])?" args)
   template
   (lambda (match r1 arg r2)
     (declare (ignore match))
     (format nil "~A~A~A"
             (or r1 "")
             (elt subs (position arg args :test #'string=))
             (or r2 "")))
   :simple-calls t))

(defun c-read-delimited-strings (&optional skip-spaces?)
  (next-char) ;; skip opening paren
  (let ((paren-depth 0)
        (acc (make-buffer)))
    (with-output-to-string (sink)
      (loop for c = (c-read-char)
            until (and (= paren-depth 0) (eql #\) c)) do
            (case c
              (#\Space (unless skip-spaces? (princ c sink)))
              (#\( (incf paren-depth) (princ c sink))
              (#\) (decf paren-depth) (princ c sink))
              (#\, (vector-push-extend (get-output-stream-string sink) acc))
              (otherwise (princ c sink)))
            finally (let ((last (get-output-stream-string sink)))
                      (unless (string= last "")
                        (vector-push-extend last acc)))))
    (map 'list #'identity acc)))

(defun read-c-macro (%in sharp)
  (declare (ignore sharp))
  ;; preprocessor directives need to be read in a separate namespace
  (let ((pp-directive (read-c-identifier (next-char))))
    (case pp-directive
      (vacietis.c:define
       (setf (lookup-define)
             (if (eql #\( (peek-char nil %in)) ;; no space between identifier and left paren
                 (let ((args     (c-read-delimited-strings t))
                       (template (string-trim '(#\Space #\Tab) (pp-read-line))))
                   ;;(dbg "read left paren...~%")
                   (lambda (substitutions)
                     (if args
                         (fill-in-template args template substitutions)
                         template)))
                 (pp-read-line))))
      (vacietis.c:undef
       (remhash (read-c-identifier (next-char))
                (compiler-state-pp *compiler-state*))
       (pp-read-line))
      (vacietis.c:include
       (let* ((delimiter
               (case (next-char)
                 (#\" #\") (#\< #\>)
                 (otherwise (read-error "Error reading include path: ~A"
                                        (pp-read-line)))))
              (include-file
               (slurp-while (lambda (c) (char/= c delimiter)))))
         (next-char)
         (if (char= delimiter #\")
             (%load-c-file (merge-pathnames
                            include-file
                            (directory-namestring
                             (or *load-truename* *compile-file-truename*
                                 *default-pathname-defaults*)))
                           *compiler-state*)
             (include-libc-file include-file))))
      (vacietis.c:if
       (push 'if preprocessor-if-stack)
       (unless (preprocessor-test (pp-read-line))
         (preprocessor-skip-branch)))
      (vacietis.c:ifdef
       (push 'if preprocessor-if-stack)
       (unless (lookup-define)
         (preprocessor-skip-branch)))
      (vacietis.c:ifndef
       (push 'if preprocessor-if-stack)
       (when (lookup-define)
         (preprocessor-skip-branch)))
      (vacietis.c:else ;; skip this branch
       (if preprocessor-if-stack
           (progn (setf (car preprocessor-if-stack) 'else)
                  (preprocessor-skip-branch))
           (read-error "Misplaced #else")))
      (vacietis.c:endif
       (if preprocessor-if-stack
           (pop preprocessor-if-stack)
           (read-error "Misplaced #endif")))
      (vacietis.c:elif
       (if preprocessor-if-stack
           (preprocessor-skip-branch)
           (read-error "Misplaced #elif")))
      (otherwise ;; line, pragma, error ignored for now
       (pp-read-line))))
  (values))

;;; types and size-of

(defun type-qualifier? (x)
  (find x *type-qualifiers*))

(defun basic-type? (x)
  (find x *basic-c-types*))

(defun unsigned-basic-type? (x)
  (find x *unsigned-basic-c-types*))

(defun c-type? (identifier)
  ;; and also do checks for struct, union, enum and typedef types
  (or (type-qualifier?        identifier)
      (basic-type?            identifier)
      (unsigned-basic-type?   identifier)
      (find identifier #(vacietis.c:struct vacietis.c:enum))
      (gethash identifier (compiler-state-typedefs *compiler-state*))))

(defvar *local-var-types* nil)

(defun size-of (x)
  (or (type-size x)
      (type-size (gethash x (or *local-var-types*
                                (compiler-state-var-types *compiler-state*))))))

(defun c-type-of (x)
  ;;(maphash #'(lambda (k v) (dbg "  func: ~S: ~S~%" k v)) (compiler-state-functions *compiler-state*))
  (if (and (constantp x) (numberp x))
      (typecase x
        (double-float 'vacietis.c:double)
        (single-float 'vacietis.c:float)
        (t 'vacietis.c:int))
      (or (when *local-var-types*
            ;;(dbg "c-type-of ~S~%" x)
            ;;(maphash #'(lambda (k v) (dbg "  ~S: ~S~%" k v)) *local-var-types*)
            (gethash x *local-var-types*))
          (gethash x (compiler-state-var-types *compiler-state*))
          (when (gethash x (compiler-state-functions *compiler-state*))
            'function))))

(defun c-type-of-exp (exp &optional base-type)
  ;;(when *local-var-types* (maphash #'(lambda (k v) (dbg "  ~S: ~S~%" k v)) *local-var-types*))
  ;;(maphash #'(lambda (k v) (dbg "  ~S: ~S~%" k v)) (compiler-state-var-types *compiler-state*))
  (let ((type
         (if (listp exp)
             (cond
               ;; XXX do other ops
               ((eq 'vacietis.c:* (car exp))
                (c-type-of-exp (cadr exp)))
               ((eq 'vacietis.c:/ (car exp))
                (c-type-of-exp (cadr exp)))
               ((eq 'vacietis.c:+ (car exp))
                (c-type-of-exp (cadr exp)))
               ((eq 'vacietis.c:- (car exp))
                (c-type-of-exp (cadr exp)))
               ((eq 'vacietis.c:= (car exp))
                (c-type-of-exp (cadr exp)))
               ((eq 'prog1 (car exp))
                (c-type-of-exp (cadr exp)))
               ((eq 'vacietis.c:deref* (car exp))
                (if base-type
                    (make-pointer-to :type base-type)
                    (let ((type (c-type-of-exp (cadr exp))))
                      (when (pointer-to-p type)
                        (pointer-to-type type)))))
               ((eq 'vacietis.c:% (car exp))
                ;; XXX assume int
                'vacietis.c:int)
               ((eq 'vacietis.c:|.| (car exp))
                (let ((struct-type (c-type-of-exp (cadr exp))))
                  (nth (caddr exp) (struct-type-slots struct-type))))
               ((eq 'vacietis.c:[] (car exp))
                (let ((type (c-type-of-exp (cadr exp))))
                  ;;(dbg "c-type of ~S: ~S~%" (cadr exp) type)
                  (when type
                    ;; should be array-type
                    (when (array-type-p type)
                      (array-type-element-type type)))))
               ((member (car exp) (mapcar #'(lambda (x) (intern (string-upcase x) :vacietis.c))
                                          '(&& |\|\|| < <= > >= == != ptr< ptr<= ptr> ptr>= ptr== ptr!=)))
                nil)
               ((member (car exp) '(- + * /))
                (c-type-of-exp (cadr exp)))
               ((gethash (car exp) (compiler-state-functions *compiler-state*))
                (c-function-return-type (gethash (car exp) (compiler-state-functions *compiler-state*))))
               (t
                ;; function
                ;; XXX
                'vacietis.c:int))
             (c-type-of exp))))
    (dbg "c-type-of-exp ~S: ~S~%" exp type)
    type))

(defun struct-name-of-type (type)
  (cond
    ((pointer-to-p type)
     (struct-name-of-type (pointer-to-type type)))
    ((struct-type-p type)
     (struct-type-name type))
    (t
     nil)))

;;; infix

(defvar *variable-declarations-base-type*)

(defun parse-infix (exp &optional (start 0) (end (when (vectorp exp) (length exp))) base-type)
  ;;(dbg "parse-infix: ~S ~S ~S~%" exp start end)
  (if (vectorp exp)
      (block nil
        (when (= 0 (length exp))
          (return))
        (when (= 1 (- end start))
          (return (parse-infix (aref exp start))))
        (labels ((cast? (x)
                   (and (vectorp x)
                        (not (find 'vacietis.c:|,| x)) ;;; casts can't contain commas, can they? function prototypes?
                        (some #'c-type? x)))
                 (match-binary-ops (table &key (lassoc t))
                   ;;(dbg "match-binary-ops: ~S   ~S ~S~%" table (1+ start) (1- end))
                   (let ((search-start (1+ start))
                         (search-end (1- end)))
                     (when (<= search-start search-end)
                       (position-if (lambda (x)
                                      (find x table))
                                    exp :start (1+ start) :end (1- end)
                                    :from-end lassoc))))
                 (parse-binary (i &optional op)
                   ;;(dbg "binary-op pre parse ~S ~S-~S-~S~%" (or op (aref exp i)) start i end)
                   (let* ((lvalue (parse-infix exp start i))
                          (rvalue (parse-infix exp (1+ i) end)))
                     (dbg "binary-op ~S ~S ~S~%" (or op (aref exp i)) lvalue rvalue)
                     (let ((c-type (if (and (not (listp lvalue)) (boundp '*variable-declarations-base-type*))
                                       *variable-declarations-base-type*
                                       (c-type-of-exp lvalue base-type)))
                           (r-c-type (c-type-of-exp rvalue))
                           (op (or op (aref exp i))))
                       (dbg "  -> type of lvalue ~S is: ~S~%" lvalue c-type)
                       (dbg "  -> type of rvalue ~S is: ~S~%" rvalue r-c-type)
                       (when (member op '(vacietis.c:|\|\|| vacietis.c:&&))
                         (when (integer-type? (c-type-of-exp lvalue))
                           (setq lvalue `(not (eql 0 ,lvalue))))
                         (when (integer-type? (c-type-of-exp rvalue))
                           (setq rvalue `(not (eql 0 ,rvalue)))))
                       (list (let ()
                               (cond
                                 ((and (pointer-to-p c-type)
                                       (or (not (listp lvalue))
                                           (not (eq 'vacietis.c:deref* (car lvalue)))))
                                  (case op
                                    ('vacietis.c:+ 'vacietis.c:ptr+)
                                    ('vacietis.c:+= 'vacietis.c:ptr+=)
                                    ('vacietis.c:- 'vacietis.c:ptr-)
                                    ('vacietis.c:-= 'vacietis.c:ptr-=)
                                    ('vacietis.c:< 'vacietis.c:ptr<)
                                    ('vacietis.c:<= 'vacietis.c:ptr<=)
                                    ('vacietis.c:> 'vacietis.c:ptr>)
                                    ('vacietis.c:>= 'vacietis.c:ptr>=)
                                    ('vacietis.c:== 'vacietis.c:ptr==)
                                    ('vacietis.c:!= 'vacietis.c:ptr!=)
                                    (t op)))
                                 ((pointer-to-p r-c-type)
                                  (case op
                                    ('vacietis.c:+ 'vacietis.c:ptr+)
                                    (t op)))
                                 ((integer-type? c-type)
                                  (case op
                                    ('vacietis.c:/ 'vacietis.c:integer/)
                                    ('vacietis.c:/= 'vacietis.c:integer/=)
                                    (t op)))
                                 (t op)))
                             lvalue
                             (if (and (constantp rvalue) (numberp rvalue))
                                 (lisp-constant-value-for c-type rvalue)
                                 rvalue))))))
          ;; in order of weakest to strongest precedence
          ;; comma
          (awhen (match-binary-ops '(vacietis.c:|,|))
            (return (parse-binary it 'progn)))
          ;; assignment
          (awhen (match-binary-ops *assignment-ops* :lassoc nil)
            (return (parse-binary it)))
          ;; elvis
          (awhen (position 'vacietis.c:? exp :start start :end end)
            (let ((?pos it))
              (return
                (let* ((test (parse-infix exp start ?pos))
                       (test-type  (c-type-of-exp test))
                       (testsym (gensym)))
                  `(let ((,testsym ,test))
                     (if ,(cond
                           ((eq 'function-pointer test-type)
                            `(and ,testsym (not (eql 0 ,testsym))))
                           ((eq 'vacietis.c:int test-type)
                            `(not (eql 0 ,testsym)))
                           (t testsym))
                         ,@(aif (position 'vacietis.c:|:| exp :start ?pos :end end)
                                (list (parse-infix exp (1+ ?pos) it)
                                      (parse-infix exp (1+ it)   end))
                                (read-error "Error parsing ?: trinary operator in: ~A"
                                            (subseq exp start end)))))))))
          ;; various binary operators
          (loop for table across *binary-ops-table* do
               (awhen (match-binary-ops table)
                 ;;(dbg "matched binary op: ~S~%" it)
                 (if (and (find (elt exp it) *ambiguous-ops*)
                          (let ((prev (elt exp (1- it))))
                            (or (find prev *ops*) (cast? prev))))
                     (awhen (position-if (lambda (x)
                                           (not (or (find x *ops*)
                                                    (cast? x))))
                                         exp
                                         :start     start
                                         :end          it
                                         :from-end      t)
                       (return-from parse-infix (parse-binary (1+ it))))
                     (return-from parse-infix (parse-binary it)))))
          ;; unary operators
          (flet ((parse-rest (i)
                   ;;(dbg "parse-rest: i: ~S  end: ~S~%" i end)
                   (parse-infix exp (1+ i) end)))
            (loop for i from start below end for x = (aref exp i) do
                 (cond ((cast? x)                               ;; cast
                        ;;(dbg "cast: x: ~S~%" x)
                        (return-from parse-infix (parse-rest i)))
                       ((find x #(vacietis.c:++ vacietis.c:--)) ;; inc/dec
                        (dbg "inc/dec: ~S~%" x)
                        (return-from parse-infix
                          (let* ((postfix? (< start i))
                                 (place    (if postfix?
                                               (parse-infix exp start  i)
                                               (parse-infix exp (1+ i) end)))
                                 (place-type (c-type-of-exp place))
                                 (__ (dbg "place-type of ~S: ~S~%" place place-type))
                                 (set-exp `(vacietis.c:=
                                            ,place
                                            (,(if (eq x 'vacietis.c:++)
                                                  ;; XXX need to do the same for --
                                                  (cond
                                                    ((pointer-to-p place-type)
                                                     'vacietis.c:ptr+)
                                                    (t 'vacietis.c:+))
                                                  (cond
                                                    ((pointer-to-p place-type)
                                                     'vacietis.c:ptr-)
                                                    (t 'vacietis.c:-)))
                                              ,place 1))))
                            (if postfix?
                                `(prog1 ,place ,set-exp)
                                set-exp))))
                       ((find x *possible-prefix-ops*)          ;; prefix op
                        ;;(dbg "prefix op: ~S  i: ~S~%" x i)
                        (return-from parse-infix
                          (if (eq x 'vacietis.c:sizeof)
                              (let ((type-exp (aref exp (1+ i))))
                                (when (vectorp type-exp) ;; fixme
                                  (setf type-exp (aref type-exp 0)))
                                (or (size-of type-exp)
                                    (read-error "Don't know sizeof ~A" type-exp)))
                              (let ((rest (parse-rest i)))
                                (cond
                                  ((eq x 'vacietis.c:!)
                                   (if (integer-type? (c-type-of-exp rest))
                                       `(if (eql 0 ,rest)
                                            1
                                            0)
                                       `(vacietis.c:! ,rest)))
                                  (t
                                   (list (case x
                                           (vacietis.c:- '-)
                                           (vacietis.c:* 'vacietis.c:deref*)
                                           (vacietis.c:& 'vacietis.c:mkptr&)
                                           (otherwise     x))
                                         rest))))))))))
          ;; funcall, aref, and struct access
          (loop for i from (1- end) downto (1+ start) for x = (aref exp i) do
               (cond
                 ((find x #(vacietis.c:|.| vacietis.c:->))
                  (let ((exp (parse-binary i)))
                    (let ((ctype (c-type-of-exp (elt exp 1))))
                      (dbg "struct accessor: ctype of ~S: ~S~%" (elt exp 1) ctype)
                      (return-from parse-infix
                        `(vacietis.c:|.|
                                     ,(if (eq x 'vacietis.c:->)
                                          `(vacietis.c:deref* ,(elt exp 1))
                                          (elt exp 1))
                                     ,(gethash (format nil "~A.~A" (struct-name-of-type ctype) (elt exp 2))
                                               (compiler-state-accessors *compiler-state*)))))))
                 ((listp x) ;; aref
                  (return-from parse-infix
                    (if (eq (car x) 'vacietis.c:[])
                        `(vacietis.c:[] ,(parse-infix exp start i)
                                        ,(parse-infix (second x)))
                        (read-error "Unexpected list when parsing ~A" exp))))
                 ((vectorp x) ;; funcall
                  (dbg "funcall: ~S~%" x)
                  (return-from parse-infix
                    (let ((fun-exp (parse-infix exp start i)))
                     (append
                      (if (symbolp fun-exp)
                          (list fun-exp)
                          (list 'funcall fun-exp))
                      (loop with xstart = 0
                            for next = (position 'vacietis.c:|,| x :start xstart)
                            when (< 0 (length x))
                              collect (parse-infix x xstart (or next (length x)))
                            while next do (setf xstart (1+ next)))))))))
          (read-error "Error parsing expression: ~A" (subseq exp start end))))
      (progn
        (let ((type (c-type-of-exp exp)))
          (dbg "type of ~S: ~S~%" exp (c-type-of-exp exp))
          (case type
            ('function
             `(fdefinition ',exp))
            (t exp))))))

;;; statements

(defun read-c-block (c)
  (if (eql c #\{)
      (loop for c = (next-char)
            until (eql c #\}) append (reverse
                                      (multiple-value-list
                                       (read-c-statement c))))
      (read-error "Expected opening brace '{' but found '~A'" c)))

(defun next-exp ()
  (read-c-exp (next-char)))

(defvar *variable-lisp-type-declarations*)
(defvar *variable-declarations*)
(defvar *cases*)

(defun read-exps-until (predicate)
  (let ((exps (make-buffer)))
    (loop for c = (next-char)
          until (funcall predicate c)
       do (progn
            ;;(dbg "read c: ~S~%" c)
            (vector-push-extend (read-c-exp c) exps)))
    exps))

(defun c-read-delimited-list (open-delimiter separator)
  (let ((close-delimiter (ecase open-delimiter (#\( #\)) (#\{ #\}) (#\; #\;)))
        (list            (make-buffer))
        done?)
    (loop until done? do
         (vector-push-extend
          (read-exps-until (lambda (c)
                             (cond ((eql c close-delimiter) (setf done? t))
                                   ((eql c separator)       t))))
          list))
    list))

(defun integer-type? (type)
  (member type
          '(vacietis.c:long vacietis.c:int vacietis.c:short vacietis.c:char
            vacietis.c:unsigned-long vacietis.c:unsigned-int vacietis.c:unsigned-short vacietis.c:unsigned-char)))

(defvar *function-name*)

(defun read-control-flow-statement (statement)
  (flet ((read-block-or-statement ()
           (let ((next-char (next-char)))
             (if (eql next-char #\{)
                 ;;#+nil ;; XXX check if tagbody exists
                 (cons 'tagbody (read-c-block next-char))
                 (read-c-statement next-char)))))
    (if (eq statement 'vacietis.c:if)
        (let* ((test       (parse-infix (next-exp)))
               (test-type  (c-type-of-exp test))
               (then       (read-block-or-statement))
               (next-char  (next-char nil))
               (next-token (case next-char
                             (#\e  (read-c-exp #\e))
                             ((nil))
                             (t    (c-unread-char next-char) nil)))
               (if-exp    (cond
                            ((eq 'function test-type)
                             (let ((testsym (gensym)))
                               `(let ((,testsym ,test))
                                  (if (and ,testsym (not (eql 0 ,testsym)))
                                      ,then
                                      ,(when (eq next-token 'vacietis.c:else)
                                             (read-block-or-statement))))))
                            ((integer-type? test-type)
                             `(if (not (eql 0 ,test))
                                    ,then
                                    ,(when (eq next-token 'vacietis.c:else)
                                           (read-block-or-statement))))
                            (t `(if ,test
                                    ,then
                                    ,(when (eq next-token 'vacietis.c:else)
                                           (read-block-or-statement))))))
               #+nil
               (if-exp    `(if (eql 0 ,test)
                               ,(when (eq next-token 'vacietis.c:else)
                                      (read-block-or-statement))
                               ,then)))
          ;;(dbg "if-exp: ~S~%" if-exp)
          (if (or (not next-token) (eq next-token 'vacietis.c:else))
              if-exp
              `(progn ,if-exp ,(%read-c-statement next-token))))
        (case statement
          ((vacietis.c:break vacietis.c:continue)
            `(go ,statement))
          (vacietis.c:goto
            `(go ,(read-c-statement (next-char))))
          (vacietis.c:return
            `(return-from ,*function-name* ,(or (read-c-statement (next-char)) 0)))
          (vacietis.c:case
            (prog1 (car (push
                         (eval (parse-infix (next-exp))) ;; must be constant int
                         *cases*))
              (unless (eql #\: (next-char))
                (read-error "Error parsing case statement"))))
          (vacietis.c:switch
            (let* ((exp     (parse-infix (next-exp)))
                   (*cases* ())
                   (body    (read-c-block (next-char))))
              `(vacietis.c:switch ,exp ,*cases* ,body)))
          (vacietis.c:while
           (let ((test (parse-infix (next-exp))))
             (dbg "while test type: ~S~%" (c-type-of-exp test))
             (cond
               ((integer-type? (c-type-of-exp test))
                `(vacietis.c:for (nil nil (not (eql 0 ,test)) nil)
                                 ,(read-block-or-statement)))
               (t
                `(vacietis.c:for (nil nil ,test nil)
                                 ,(read-block-or-statement)))))
           #+nil
           `(vacietis.c:for (nil nil ,(parse-infix (next-exp)) nil)
                            ,(read-block-or-statement)))
          (vacietis.c:do
            (let ((body (read-block-or-statement)))
              (if (eql (next-exp) 'vacietis.c:while)
                  (let ((test (parse-infix (next-exp))))
                    (prog1 `(vacietis.c:do ,body ,(if (integer-type? (c-type-of-exp test)) `(not (eql 0 ,test)) test))
                      (read-c-statement (next-char)))) ;; semicolon
                  (read-error "No 'while' following a 'do'"))))
          (vacietis.c:for
            `(vacietis.c:for
                 ,(let* ((*local-var-types*       (make-hash-table))
                         (*variable-declarations* ()) ;; c99, I think?
                         (*variable-lisp-type-declarations* ())
                         (initializations         (progn
                                                    (next-char)
                                                    (read-c-statement
                                                     (next-char)))))
                        (list* *variable-declarations*
                               initializations
                               (map 'list
                                    #'parse-infix
                                    (c-read-delimited-list #\( #\;))))
               ,(read-block-or-statement)))))))

(defun read-function (name result-type)
  ;;(declare (ignore result-type))
  (let (arglist
        arglist-type-declarations
        (*function-name* name)
        (*local-var-types* (make-hash-table)))
    (block done-arglist
      (loop for param across (c-read-delimited-list (next-char) #\,) do
           (block done-arg
             (let ((ptrlev 0)
                   (arg-type
                    (when (and (vectorp param) (c-type? (aref param 0)))
                      (aref param 0))))
               (labels ((strip-type (x)
                          (cond ((symbolp x)
                                 (if (> ptrlev 0)
                                     (let ((type arg-type))
                                       (loop while (> ptrlev 0)
                                          do (setq type (make-pointer-to :type type))
                                            (decf ptrlev))
                                       (setf (gethash x *local-var-types*) type))
                                     (setf (gethash x *local-var-types*) arg-type))
                                 (push x arglist)
                                 (return-from done-arg))
                                ((vectorp x)
                                 (loop for x1 across x do
                                      (when (not (or (c-type? x1)
                                                     (eq 'vacietis.c:* x1)))
                                        (strip-type x1))))
                                (t
                                 (read-error
                                  "Junk in argument list: ~A" x)))))
                 (when (and (vectorp param) (c-type? (aref param 0)))
                   (dbg "  param: ~S~%" param)
                   (when (and (= (length param) 3) (equalp #() (aref param 2)))
                     (setq arg-type 'function-pointer))
                   (push (lisp-type-declaration-for param)
                         arglist-type-declarations))
                 (loop for x across param do
                      (cond
                        ((eq x 'vacietis.c:|.|)
                         (progn (push '&rest            arglist)
                                (push 'vacietis.c:|...| arglist)
                                (return-from done-arglist)))
                        ((eq 'vacietis.c:* x)
                         (incf ptrlev))
                        ((not (or (c-type? x) (eq 'vacietis.c:* x)))
                         (strip-type x)))))))))
    (if (eql (peek-char nil %in) #\;)
        (prog1 t (c-read-char)) ;; forward declaration
        (let ((ftype `(ftype (function ,(make-list (length arglist) :initial-element '*) ,(lisp-type-for result-type)) ,name)))
          (when (find '&rest arglist)
            (setq ftype nil))
          (dbg "result type of ~S: ~S~%" name result-type)
          (dbg "ftype: ~S~%" ftype)
          (setf (gethash name (compiler-state-functions *compiler-state*))
                (make-c-function :return-type result-type))
          `(progn
             ,@(when ftype (list `(declaim ,ftype)))
             (vac-defun/1 ,name ,(reverse arglist)
               (declare ,@(remove-if #'null arglist-type-declarations))
               ,(let* ((*variable-declarations* ())
                       (*variable-lisp-type-declarations* ())
                       (body                    (read-c-block (next-char))))
                      `(prog* ,(reverse *variable-declarations*)
                          (declare ,@(remove-if #'null *variable-lisp-type-declarations*))
                          ,@body))))))))

(defun get-dimensions (name1 &optional dimensions)
  (dbg "get-dimensions name1: ~S~%" name1)
  (let ((dim1 (third name1)))
    (if (listp (second name1))
      (nconc dimensions (get-dimensions (second name1)) (list dim1))
      (nconc dimensions (list dim1)))))

(defun get-elements (base-type dimensions value)
  (if (= 1 (length dimensions))
      (map 'vector #'(lambda (x)
                       ;;(dbg "element value: ~S~%" x)
                       (if (vector-literal-p x)
                           (let ((elements (vector-literal-elements x)))
                             (get-elements base-type (list (length elements)) x))
                           ;; XXX fix this
                           (let ((constant-value (ignore-errors (eval x))))
                             (if constant-value
                                 (lisp-constant-value-for base-type constant-value)
                                 x))))
           (vector-literal-elements value))
      (map 'vector #'(lambda (x)
                       (get-elements base-type (cdr dimensions) x))
           (vector-literal-elements value))))

(defun to-lisp-array (base-type name1 value)
  (let ((dimensions (get-dimensions name1)))
    (if (null (car dimensions))
        (remove-if #'null (get-elements base-type dimensions value))
        ;;(get-elements base-type dimensions value)
        (let ((elements (get-elements base-type dimensions value))
              (lisp-type (lisp-type-for base-type)))
          (dbg "making array of dimensions ~S~%" dimensions)
          (dbg "elements: ~S~%" elements)
          (if (find-if-not #'(lambda (x) (typep x lisp-type)) elements)
              (values `(make-array ',dimensions
                                   :element-type ',lisp-type
                                   :initial-contents (list ,@(map 'list #'identity elements)))
                      dimensions)
              (values (make-array dimensions
                                  :element-type (lisp-type-for base-type)
                                  :initial-contents elements)
                      dimensions))))))

;; for an array of struct typed objects
(defun pass2-struct-array (type array)
  (loop for i from 0 upto (1- (length array)) do
       (let ((row (aref array i)))
         (loop for j from 0 upto (1- (length row)) do
              (let ((it (aref row j)))
                (cond
                  ((vectorp it)
                   (let* ((slot-type (nth j (slot-value type 'slots)))
                          (element-type (slot-value slot-type 'element-type)))
                     ;;(dbg "element-type: ~S (~S)~%" element-type (length it))
                     (setf (aref row j)
                           (make-array (length it)
                                       :element-type (lisp-type-for element-type)
                                       :initial-contents it))))))))))

(defun to-struct-value (type value)
  (let ((row (map 'vector #'identity (vector-literal-elements value))))
    (dbg "lisp-type: ~S~%" (lisp-type-for type))
    (dbg "row: ~S~%" row)
    (let* ((lisp-type (lisp-type-for type))
           (element-type (cadr lisp-type)))
      (make-array (length row)
                  :element-type element-type
                  :initial-contents row))))

(defun process-variable-declaration (spec base-type)
  (let (name (type base-type) initial-value init-size)
    (labels ((init-object (name1 value)
               (if (vector-literal-p value)
                   (let () ;;((els (cons 'vector (vector-literal-elements value))))
                     ;; (vacietis.c:[] elp10 nil)
                     ;; name1: (vacietis.c:[] (vacietis.c:[] del 4) 5)
                     ;; name1: (vacietis.c:[] (vacietis.c:[] (vacietis.c:[] del 3) 4) 5)
                     (dbg "variable declaration of ~S: type: ~S name1: ~S~%" name type name1)
                     (if (struct-type-p type)
                         (if (symbolp name)
                             (to-struct-value type value)
                             (let ((array (to-lisp-array base-type name1 value)))
                               (pass2-struct-array type array)
                               (setf init-size (length array))
                               array))
                         (progn
                           (multiple-value-bind (array dimensions)
                               (to-lisp-array base-type name1 value)
                             (setf init-size dimensions)
                             array))
                         #+nil ;; ...
                         (progn (setf init-size (length els))
                                `(vacietis::make-memptr :mem ,els))))
                   (progn
                     (when (and (listp value) (eq 'string-to-char* (car value)))
                       (setf init-size (1+ (length (second value)))))
                     (progn
                       (dbg "initial value of ~S (type ~S): ~S~%" name type value)
                       value))))
             (parse-declaration (x)
               (if (symbolp x)
                   (setf name x)
                   (destructuring-bind (qualifier name1 &optional val/size)
                       x
                     (setf name name1)
                     (dbg "qualifier: ~S~%" qualifier)
                     (case qualifier
                       (vacietis.c:=
                        (setf initial-value (init-object name1 val/size))
                        (parse-declaration name1))
                       (vacietis.c:[]
                        (setf type
                              (make-array-type
                               :element-type type
                               :dimensions   (awhen (or val/size init-size)
                                               (dbg "array dimensions: ~S~%" it)
                                               (if (listp it)
                                                   (list (eval it))
                                                   (list it)))))
                        (parse-declaration name))
                       (vacietis.c:deref*
                        (setf type (make-pointer-to :type type))
                        (dbg "set type to ~S~%" type)
                        ;;XXX what about actual pointers to pointers?
                        (unless (and (listp initial-value) (eq (car initial-value) 'vacietis.c:mkptr&))
                          (setq initial-value `(vacietis.c:mkptr& (aref ,initial-value 0))))
                        (parse-declaration name))
                       (t (read-error "Unknown thing in declaration ~A" x)))))))
      ;;(dbg "spec: ~S~%" spec)
      (parse-declaration spec)
      (values name type initial-value))))

(defvar *is-extern*)
(defvar *is-const*)
(defvar *is-unsigned*)

(defun read-variable-declarations (spec-so-far base-type)
  (let* ((*variable-declarations-base-type* base-type)
         (decls      (c-read-delimited-list #\; #\,))
         (decl-code  ()))
    (setf (aref decls 0) (concatenate 'vector spec-so-far (aref decls 0)))
    ;;(dbg "rvd: spec-so-far: ~S ~S~%" spec-so-far base-type)
    (loop for x across decls do
         (dbg "processing variable declaration of ~S with base-type ~S~%" x base-type)
         (multiple-value-bind (name type initial-value)
             (process-variable-declaration (parse-infix x 0 (length x) base-type) base-type)
           (dbg "setting local-var-type of ~S  (extern: ~S)  to ~S~%" name *is-extern* type)
           (dbg "  -> initial-value: ~S~%" initial-value)
           (setf (gethash name (or *local-var-types*
                                   (compiler-state-var-types *compiler-state*)))
                 type)
           (if (boundp '*variable-declarations*)
               (progn (push `(,name ,@(if initial-value
                                          (list initial-value)
                                          (list (preallocated-value-exp-for type))))
                            *variable-declarations*)
                      (push (lisp-type-declaration-for type name)
                            *variable-lisp-type-declarations*)
                      (dbg "variable decl: ~S~%" (list type name (preallocated-value-exp-for type)))
                      #+nil
                      (when initial-value
                        (push `(vacietis.c:= ,name ,initial-value)
                              decl-code)))
               (unless *is-extern*
                 (dbg "global type: ~S~%" type)
                 (let* ((defop 'defparameter)
                        (varname name)
                        (varvalue (or initial-value
                                      (preallocated-value-exp-for type)))
                        (declamation `(declaim (type ,(lisp-type-for type) ,varname))))
                   (dbg "declamation: ~S~%" declamation)
                   (push declamation
                         decl-code)
                   (push `(,defop ,varname
                            ,varvalue)
                         decl-code)
                   #+nil
                   (push declamation
                         decl-code))))))
    (if decl-code
        (cons 'progn (nreverse decl-code))
        t)))

(defun read-var-or-function-declaration (base-type)
  "Reads a variable(s) or function declaration"
  (dbg "read-var-or-function-declaration: ~S~%" base-type)
  (let ((type base-type)
        name
        (spec-so-far (make-buffer)))
    (loop for c = (next-char) do
         (cond ((eql c #\*)
                (setf type        (make-pointer-to :type type))
                (vector-push-extend 'vacietis.c:* spec-so-far))
               ((or (eql c #\_) (alpha-char-p c))
                (setf name (read-c-identifier c))
                (vector-push-extend name spec-so-far)
                (return))
               (t
                (c-unread-char c)
                (return))))
    (let ((next (next-char)))
      (c-unread-char next)
      (if (and name (eql #\( next))
          (read-function name type)
          (read-variable-declarations spec-so-far base-type)))))

(defun read-enum-decl ()
  (when (eql #\{ (peek-char t %in))
    (next-char)
    (let ((enums (c-read-delimited-list #\{ #\,)))
      ;; fixme: assigned values to enum names
      (loop for name across enums for i from 0 do
           (setf (gethash (elt name 0) (compiler-state-enums *compiler-state*))
                 i))))
  (if (eql #\; (peek-char t %in))
      (progn (next-char) t)
      (read-variable-declarations #() 'vacietis.c:int)))

(defun modify-base-type (base-type)
  (cond
    (*is-unsigned*
     (case base-type
       ('vacietis.c:char   'vacietis.c:unsigned-char)
       ('vacietis.c:short  'vacietis.c:unsigned-short)
       ('vacietis.c:int    'vacietis.c:unsigned-int)
       ('vacietis.c:long   'vacietis.c:unsigned-long)
       (t base-type)))
    (t base-type)))

(defun read-base-type (token)
  (dbg "read-base-type: ~S~%" token)
  (loop while (type-qualifier? token)
     do
       (dbg "type qualifier token: ~S~%" token)
       (case token
         ('vacietis.c:extern
          (setq *is-extern* t))
         ('vacietis.c:unsigned
          (setq *is-unsigned* t))
         ('vacietis.c:const
          (setq *is-const* t)))
       (setf token (next-exp)))
  (awhen (gethash token (compiler-state-typedefs *compiler-state*))
    (setf token it))
  (cond ((eq token 'vacietis.c:enum)
         (values (make-enum-type :name (next-exp)) t))
        ((eq token 'vacietis.c:struct)
         (dbg "  -> struct~%")
         (if (eql #\{ (peek-char t %in))
             (progn
               (c-read-char)
               (values (read-struct-decl-body (make-struct-type)) t))
             (let ((name (next-exp)))
               (dbg "  -> struct name: ~S~%" name)
               (values (or (gethash name (compiler-state-structs *compiler-state*))
                           (make-struct-type :name name)) t))))
        ((or (basic-type? token) (c-type-p token))
         (values (modify-base-type token) nil))
        (t
         (read-error "Unexpected parser error: unknown type ~A" token))))

(defun read-struct-decl-body (struct-type)
  (let ((i 0))
    (loop for c = (next-char) until (eql #\} c) do
         (multiple-value-bind (slot-name slot-type)
             (let ((base-type (read-base-type (read-c-exp c))))
               (process-variable-declaration (read-infix-exp (next-exp))
                                             base-type))
           (setf (gethash (format nil "~A.~A" (slot-value struct-type 'name) slot-name)
                          (compiler-state-accessors *compiler-state*))
                 i
                 (struct-type-slots struct-type)
                 (append (struct-type-slots struct-type) (list slot-type)))
           ;;(dbg "struct-type: ~S slot-name ~A i: ~D~%" struct-type slot-name i)
           ;; use a vector
           (incf i)
           #+nil
           (incf i (size-of slot-type))))))

(defun read-c-identifier-list (c)
  (map 'list (lambda (v)
               (if (= 1 (length v))
                   (aref v 0)
                   v))
       (c-read-delimited-list #\; #\,)))

(defun read-struct (struct-type &optional for-typedef)
  (acase (next-char)
    (#\{ (read-struct-decl-body struct-type)
         (awhen (struct-type-name struct-type)
           (setf (gethash it (compiler-state-structs *compiler-state*))
                 struct-type))
         (let ((c (next-char)))
           (if (eql #\; c)
               t
               (progn (c-unread-char c)
                      (if for-typedef
                          (read-c-identifier-list c)
                          (read-variable-declarations #() struct-type))))))
    (#\; t) ;; forward declaration
    (t   (if for-typedef
             (progn (c-unread-char it)
                    (read-c-identifier-list it))
             (read-variable-declarations (vector (read-c-exp it))
                                         struct-type)))))

(defun read-typedef (base-type)
  (dbg "read-typedef: ~S~%" base-type)
  (cond ((struct-type-p base-type)
         (let ((names (read-struct base-type t)))
           (dbg "typedef read-struct names: ~S~%" names)
           (dolist (name names)
             (when (symbolp name) ;; XXX handle pointer and array typedefs
               (setf (gethash name (compiler-state-typedefs *compiler-state*)) base-type)))
           t))
        (t
         (multiple-value-bind (name type)
             (process-variable-declaration (read-infix-exp (next-exp)) base-type)
           (setf (gethash name (compiler-state-typedefs *compiler-state*)) type)
           t))))

(defun read-declaration (token)
  (cond ((eq 'vacietis.c:typedef token)
         (let ((*is-unsigned* nil))
           (let* ((*is-extern* nil)
                  (*is-const* nil)
                  (*is-unsigned* nil)
                  (base-type (read-base-type (next-exp))))
             (read-typedef base-type))))
        ((c-type? token)
         (let* ((*is-extern* nil)
                (*is-const* nil)
                (*is-unsigned* nil))
           (multiple-value-bind (base-type is-decl)
               (read-base-type token)
             (dbg "read-declaration base-type: ~S~%" base-type)
             (if is-decl
                 (cond ((struct-type-p base-type)
                        (read-struct base-type))
                       ((enum-type-p base-type)
                        (read-enum-decl)))
                 (read-var-or-function-declaration base-type)))))))

(defun read-labeled-statement (token)
  (when (eql #\: (peek-char t %in))
    (next-char)
    (values (read-c-statement (next-char)) token)))

(defun read-infix-exp (next-token)
  (let ((exp (make-buffer)))
    (vector-push-extend next-token exp)
    (loop for c = (next-char nil)
          until (or (eql c #\;) (null c))
          do (vector-push-extend (read-c-exp c) exp))
    (parse-infix exp)))

(defun %read-c-statement (token)
  (multiple-value-bind (statement label) (read-labeled-statement token)
    (acond (label                    (values statement label))
           ((read-declaration token) (if (eq t it) (values) it))
           (t                        (or (read-control-flow-statement token)
                                         (read-infix-exp token))))))

(defun read-c-statement (c)
  (case c
    (#\# (read-c-macro %in c))
    (#\; (values))
    (t   (%read-c-statement (read-c-exp c)))))

(defun read-c-identifier (c)
  ;; assume inverted readtable (need to fix for case-preserving lisps)
  (let* ((raw-name (concatenate
                    'string (string c)
                    (slurp-while (lambda (c)
                                   (or (eql c #\_) (alphanumericp c))))))
         (raw-name-alphas (remove-if-not #'alpha-char-p raw-name))
         (identifier-name
          (format nil
                  (cond ((every #'upper-case-p raw-name-alphas) "~(~A~)")
                        ((every #'lower-case-p raw-name-alphas) "~:@(~A~)")
                        (t "~A"))
                  raw-name)))
    ;;(format t "identifier-name: ~S~%" identifier-name)
    (let ((symbol (or (find-symbol identifier-name '#:vacietis.c)
                      (intern identifier-name)
                      ;;(intern (string-upcase identifier-name))
                      )))
      (case symbol
        ('t '__c_t)
        (t symbol)))))

(defun match-longest-op (one)
  (flet ((seq-match (&rest chars)
           (find (make-array (length chars)
                             :element-type 'character
                             :initial-contents chars)
                 *ops* :test #'string= :key #'symbol-name)))
    (let ((one-match (seq-match one))
          (two (c-read-char)))
      (acond ((null two)
              one-match)
             ((seq-match one two)
              (let ((three-match (seq-match one two (peek-char nil %in))))
                (if three-match
                    (progn (c-read-char) three-match)
                    it)))
             (t (c-unread-char two) one-match)))))

(defstruct vector-literal
  elements)

(defun read-vector-literal ()
  (make-vector-literal
   :elements (map 'list #'parse-infix (c-read-delimited-list #\{ #\,))))

(defun read-c-exp (c)
  (or (match-longest-op c)
      (cond ((digit-char-p c) (read-c-number c))
            ((or (eql c #\_) (alpha-char-p c))
             (let ((symbol (read-c-identifier c)))
               ;;(dbg "~S -> symbol: ~S~%" c symbol)
               #+nil
               (when (eq t symbol)
                 (setq symbol '__c_t))
               (acond
                 ((gethash symbol (compiler-state-pp *compiler-state*))
                  ;;(describe it)
                  (setf *macro-stream*
                        (make-string-input-stream
                         (etypecase it
                           (string
                            it)
                           (function
                            (funcall it (c-read-delimited-strings)))))
                        %in
                        (make-concatenated-stream *macro-stream* %in))
                  ;;(dbg "read-c-exp...~%")
                  (read-c-exp (next-char)))
                 ((gethash symbol (compiler-state-enums *compiler-state*))
                  ;;(dbg "returning it...~%")
                  it)
                 (t
                  symbol))))
            (t
             (case c
               (#\" (read-c-string %in c))
               (#\' (read-character-constant %in c))
               (#\( (read-exps-until (lambda (c) (eql #\) c))))
               (#\{ (read-vector-literal)) ;; decl only
               (#\[ (list 'vacietis.c:[]
                          (read-exps-until (lambda (c) (eql #\] c))))))))))

;;; readtable

(defun read-c-toplevel (%in c)
  (let* ((*macro-stream* nil)
         (exp1           (read-c-statement c)))
    ;;(dbg "toplevel: ~S~%" exp1)
    (if (and *macro-stream* (peek-char t *macro-stream* nil))
        (list* 'progn
               exp1
               (loop while (peek-char t *macro-stream* nil)
                     collect (read-c-statement (next-char))))
        (or exp1 (values)))))

(macrolet
    ((def-c-readtable ()
       `(defreadtable c-readtable
         (:case :invert)

         ;; unary and prefix operators
         ,@(loop for i in '(#\+ #\- #\~ #\! #\( #\& #\*)
              collect `(:macro-char ,i 'read-c-toplevel nil))

         (:macro-char #\# 'read-c-macro nil)

         (:macro-char #\/ 'read-c-comment nil)

         (:macro-char #\" 'read-c-string nil)
         (:macro-char #\' 'read-character-constant nil)

         ;; numbers (should this be here?)
         ,@(loop for i from 0 upto 9
              collect `(:macro-char ,(digit-char i) 'read-c-toplevel nil))

         ;; identifiers
         (:macro-char #\_ 'read-c-toplevel nil)
         ,@(loop for i from (char-code #\a) upto (char-code #\z)
              collect `(:macro-char ,(code-char i) 'read-c-toplevel nil))
         ,@(loop for i from (char-code #\A) upto (char-code #\Z)
              collect `(:macro-char ,(code-char i) 'read-c-toplevel nil))
         )))
  (def-c-readtable))

(defvar c-readtable (find-readtable 'c-readtable))

;;; reader

(defun cstr (str)
  (dbg "cstr: ~S~%" str)
  (with-input-from-string (s str)
    (let ((*compiler-state* (make-compiler-state))
          (*readtable*      c-readtable))
      (let ((body (cons 'progn (loop for it = (read s nil 'eof)
                                  while (not (eq it 'eof)) collect it))))
        (eval `(vac-progn/1 ,body))))))

(defun cstr-noeval (str)
  (with-input-from-string (s str)
    (let ((*compiler-state* (make-compiler-state))
          (*readtable*      c-readtable))
      (let ((body (cons 'progn (loop for it = (read s nil 'eof)
                                  while (not (eq it 'eof)) collect it))))
        body))))

(defun %load-c-file (*c-file* *compiler-state*)
  (let ((*readtable*   c-readtable)
        (*line-number* 1))
    (load *c-file*)))

(defun load-c-file (file)
  (%load-c-file file (make-compiler-state)))
