(in-package :cepl-gl)
;;[TODO] gl-value has no type differentiator
;;----------------------
;; [TODO] Should array-type store (:struct thing) ? Yes.
(defclass gl-array ()
  ((pointer :initform nil :initarg :pointer :reader pointer)
   (len :initform nil :initarg :len :reader array-length)
   (type :initform nil :initarg :type :reader array-type)
   (row-byte-size :initarg :row-byte-size :reader row-byte-size)
   (row-alignment :initarg :row-alignment :reader row-alignment)
   (dimensions :initarg :dimensions :reader dimensions)))

(defclass gl-struct-array (gl-array) nil)
(defclass gl-value (gl-array) nil)

(defmethod print-object ((object gl-array) stream)
  (format stream "#.<GL-ARRAY :type ~s :length ~a>"
          (slot-value object 'type)
          (slot-value object 'dimensions)))

(defmethod print-object ((object gl-value) stream)
  (format stream "#.<GL-VALUE :type ~s>"
          (slot-value object 'type)))

;; [TODO] The :struct assumtion is incorrect
(defun gl-calc-byte-size (type dimensions &optional (alignment 1))
  (if (loop for i in '(1 2 3 4) never (eql i 0))
      (let* ((dimensions (if (listp dimensions) dimensions (list dimensions)))
             (x-size (or (first dimensions) 1))
             (y-size (or (second dimensions) 1))
             (z-size (or (third dimensions) 1))
             (w-size (or (fourth dimensions) 1)))
        (let* ((type-byte-size (cffi:foreign-type-size type))
               (row-raw-size (* x-size type-byte-size))
               (row-mod (mod row-raw-size alignment))
               (row-byte-size (if (eql row-mod 0) row-raw-size
                                  (+ row-raw-size row-mod))))
          (* row-byte-size y-size z-size w-size)))
      (error "no dimensions can be 0")))

(defgeneric make-gl-array (element-type dimensions 
                           &optional initial-contents pointer
                             alignment))

(defmethod make-gl-array ((element-type t) dimensions
                          &optional initial-contents pointer
                            (alignment 1))
  (let* ((byte-length (gl-calc-byte-size element-type dimensions alignment))
         (array (make-instance
                 'gl-array
                 :type element-type
                 :pointer (or pointer (foreign-alloc :char 
                                                     :count byte-length))
                 :len (apply #'* dimensions)
                 :row-byte-size byte-length
                 :row-alignment alignment
                 :dimensions dimensions)))
    (when initial-contents (destructuring-populate array initial-contents))
    array))

;;----------------------

(defmacro dangerous-defctype (name base-type &optional documentation)
  "Utility macro for simple C-like typedefs."
  (declare (ignore documentation))
  (let* ((btype (cffi::parse-type base-type))
         (dtype (if (typep btype 'cffi::enhanced-foreign-type)
                    'cffi::enhanced-typedef
                    'cffi::foreign-typedef)))
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (cffi::notice-foreign-type 
        ',name (make-instance ',dtype :name ',name :actual-type ,btype)))))

(defun agg-type-helper-name (type)
  (utils:symb-package 'cepl-gl 'cgl- (varjo:type-principle type)))

(defmacro make-foreign-helper-types ()
  `(progn 
     ,@(loop :for (type . len) :in varjo::*glsl-component-counts*
          :collect 
          (let* ((ftype (varjo:flesh-out-type type))
                 (comp-len (varjo:type-component-count type))
                 (comp-type (varjo:type-component-type ftype))) 
            `(progn
               (defcstruct ,(utils:symb 'cgl- type)
                 (components ,comp-type :count ,len))
               (dangerous-defctype ,type (:struct ,(utils:symb 'cgl- type)))
               (defclass ,(utils:symb type) (gl-array)
                 ((type :initform ,type)))
               (defmethod make-gl-array ((element-type (eql 'type)) dimensions
                                         &optional initial-contents pointer
                                           (alignment 1))
                 (let* ((byte-length (gl-calc-byte-size element-type dimensions 
                                                        alignment))
                        (array (make-instance
                               ',(utils:symb type) 
                                :type element-type
                                :pointer (or pointer (foreign-alloc :char 
                                                                    :count byte-length))
                                :len (apply #'* dimensions)
                                :row-byte-size byte-length
                                :row-alignment alignment
                                :dimensions dimensions)))
                   (when initial-contents (destructuring-populate array initial-contents))
                   array))
               (defmethod glpush-entry ((gl-array ,(utils:symb type))
                                        index value)
                 (let ((v-ptr (mem-aptr (pointer gl-array)
                                        ,type index)))
                   ,@(loop :for j :below comp-len
                        :collect `(setf (mem-aref v-ptr ,comp-type ,j) 
                                        (aref value ,j)))
                   value))
               (defmethod destructuring-populate ((gl-array ,(utils:symb type)) data)
                 (let ((a-ptr (pointer gl-array)))
                   (loop :for datum :in data
                      :for i :from 0
                      :do (let ((v-ptr (mem-aptr a-ptr ,type i)))
                            ,@(loop :for j :below comp-len
                                 :collect  
                                 `(setf (mem-aref v-ptr ,comp-type ,j)
                                        (aref datum ,j))))))
                 gl-array)
               (defmethod glpull-entry ((gl-array ,(utils:symb type)) index)  
                 (let ((ptr (mem-aptr (pointer gl-array)
                                      ,type index)))
                   (make-array 
                    ,comp-len
                    ;; [TODO] :element-type 'need-to-fix-this
                    :initial-contents 
                    (list ,@(loop :for j :below comp-len
                               :collect  
                               `(mem-aref ptr ,comp-type
                                          ,j)))))))))))

(make-foreign-helper-types)

;;------------------------------------------------------------
;; Homeless functions

(defgeneric destructuring-populate (gl-array data)
  (:documentation 
   "This function takes a gl-array and a list of data and 
   populates the gl-array using the data. 
   The data must be a list of sublists. Each sublist must
   contain the data for the attributes of the gl-array's type.  
   That sucks as an explanation so here is an example:

   given a format as defined below:
    (cgl:define-interleaved-attribute-format vert-data 
      (:type :float :components (x y z))
      (:type :float :components (r g b a)))

   and an array made using this format
    (setf *vertex-data-gl* (cgl:make-gl-array 'vert-data :length 3))

   then you can populate it as so:
    (cgl:destructuring-populate *vertex-data-gl*
     	   '((#( 0.0     0.5  0.0)
		      #( 1.0     0.0  0.0  1.0))

			 (#( 0.5  -0.366  0.0)
			  #( 0.0     1.0  0.0  1.0))

			 (#(-0.5  -0.366  0.0)
			  #( 0.0     0.0  1.0  1.0))))

   Hopefully that makes sense."))

(defmethod destructuring-populate ((gl-array gl-array) data)
  (loop for datum in data
	 for i from 0
	 :do (setf (aref-gl gl-array i) datum))
  gl-array)

(defgeneric gl-assign-attrib-pointers (array-type &optional attrib-num 
                                              pointer-offset
                                              stride-override
                                              normalised))

(defmethod gl-assign-attrib-pointers ((array-type t) &optional (attrib-num 0)
                                                 (pointer-offset 0)
                                                 stride-override
                                                 normalised)
  (let ((type (varjo:flesh-out-type array-type)))
    (if (varjo:type-built-inp type)
        (let ((slot-layout (expand-slot-to-layout 
                            (list type normalised)))
              (stride 0))
          (loop :for attr :in slot-layout
             :for i :from 0
             :with offset = 0
             :do (progn 
                   (gl:enable-vertex-attrib-array (+ attrib-num i))
                   (%gl:vertex-attrib-pointer 
                    (+ attrib-num i) (first attr) (second attr)
                    (third attr) (or stride-override stride)
                    (cffi:make-pointer (+ offset pointer-offset))))
             :do (setf offset (+ offset (* (first attr) 
                                           (cffi:foreign-type-size
                                            (second attr))))))
          (length slot-layout))
        (error "Type ~a is not known to cepl" type))))

(defgeneric glpull-entry (gl-array index)
  (:documentation 
   "Pull one entry from a glarray"))

(defgeneric glpush-entry (gl-array index value)
  (:documentation 
   "Push one entry to a glarray"))

(defmethod glpull-entry ((gl-array t) index) 
  (mem-aref (pointer gl-array) (array-type gl-array) index))

(defmethod glpush-entry ((gl-array t) index value) 
  (setf (mem-aref (pointer gl-array) (array-type gl-array) index)
        value))

;;[TODO] make sure this is used correctly
(defun foreign-type-index (type index)
  (* (cffi:foreign-type-size type)
     index))

;;------------------------------------------------------------

;; [TODO] :element-type (turn core type to lisp type)
(defun make-aggregate-getter (type-name slot-name slot-type)
  (let ((len (varjo:type-component-count slot-type))
        (core-type (varjo:type-component-type slot-type))
        (slot-pointer (gensym "slot-pointer")))
    `(let ((,slot-pointer (foreign-slot-pointer pointer '(:struct ,type-name)
                                              ',slot-name)))
       (make-array ,len
                   :initial-contents
                   (list ,@(loop 
                              :for i :below len
                              :collect  
                              `(mem-aref ,slot-pointer 
                                         ,core-type ,i)))))))

;; [TODO] This will have problems when making values
(defun make-gl-struct-slot-getters (type-name slots) 
  (loop :for (slot-name slot-type norm accessor-name) :in slots
     :collect
     `(progn
        (defgeneric ,(or accessor-name (utils:symb type-name '- slot-name)) 
            (object))
        (defmethod ,(or accessor-name (utils:symb type-name '- slot-name)) 
            ((object gl-value))
          (let ((pointer (pointer object)))
            ,(cond ((varjo:type-arrayp slot-type) 
                    `(make-gl-array
                      ',(if (varjo:type-aggregate-p
                             (varjo:type-principle slot-type))
                            `(:struct ,(agg-type-helper-name slot-type))
                            (let ((stype (varjo:type-principle slot-type)))
                              (if (keywordp stype) stype `(:struct ,stype))))
                      ,(varjo:type-array-length slot-type)
                      nil
                      (foreign-slot-pointer pointer '(:struct ,type-name)
                                            ',slot-name)))
                   ((not (varjo:type-built-inp slot-type))
                    `(make-instance 'gl-value
                                    :type '(:struct ,slot-type)
                                    :pointer (foreign-slot-pointer 
                                              pointer '(:struct ,type-name)
                                              ',slot-name)
                                    :len 1))
                   (t (if (varjo:type-aggregate-p slot-type)
                          (make-aggregate-getter type-name slot-name
                                                 slot-type)
                          `(foreign-slot-value pointer 
                                               '(:struct,type-name)
                                               ',slot-name)))))))))

(defun make-aggregate-setter (type-name slot-name slot-type
                              value)
  (let ((len (varjo:type-component-count slot-type))
        (core-type (varjo:type-component-type slot-type))
        (slot-pointer (gensym "slot-pointer")))
    `(let ((,slot-pointer (foreign-slot-pointer pointer '(:struct ,type-name)
                                              ',slot-name)))
       ,@(loop :for i :below len
            :collect `(setf (mem-aref ,slot-pointer ,core-type ,i)
                            (aref ,value ,i))))))

;; [TODO] What does *-ptr even mean here?... gotta consider this well
;; [TODO] We do have a way of setting a struct by value... how shall we use it?
(defun make-gl-struct-slot-setters (type-name slots) 
  (loop :for (slot-name slot-type norm accessor-name) :in slots
     :collect
     `(progn
        (defgeneric (setf ,(or accessor-name (utils:symb type-name '- slot-name))) 
            (value object))
        (defmethod (setf ,(or accessor-name (utils:symb type-name '- slot-name))) 
            (value (object gl-value))
          (let ((pointer (pointer object)))
            ,(if (or (varjo:type-arrayp slot-type) 
                     (not (varjo:type-built-inp slot-type)))
                 `(error "GLSTRUCT SETTER ERROR: Sorry, you cannot directly set a foreign slot of type array or struct: ~s ~s" value pointer)
                 (if (varjo:type-aggregate-p slot-type)
                     (make-aggregate-setter type-name slot-name
                                            slot-type 'value)
                     `(setf (foreign-slot-value pointer '(:struct ,type-name)
                                                ',slot-name)
                            value))))
          value))))


(defun make-gl-struct-dpop (type-name slots)
  (let ((loop-token (gensym "LOOP"))
        (slot-names (mapcar #'slot-name slots)))
    `(defmethod destructuring-populate ((gl-array ,type-name) data)
       (loop for ,slot-names in data
          for ,loop-token from 0
          do ,@(loop for (slot-name i j accessor-name) in slots
                  collect
                    `(setf (,(or accessor-name
                                 (utils:symb type-name 
                                             '- slot-name))
                             (aref-gl gl-array ,loop-token))
                           ,slot-name)))
       gl-array)))

(defun make-gl-struct-glpull (type-name slots)
  `(defmethod glpull-entry ((gl-array ,type-name)
                            index)
     (let ((entry (aref-gl gl-array index)))
       (list ,@(loop for (slot-name i j accessor-name) in slots
                  collect
                    `(,(or accessor-name
                           (utils:symb type-name '- slot-name))
                       entry))))))

(defun expand-slot-to-layout (slot)
  (destructuring-bind (type normalise &rest ign)
      slot
    (declare (ignore ign))
    (let ((type (varjo:flesh-out-type type)))
      (cond 
        ((varjo:type-arrayp type) 
         (loop for i below (varjo:type-array-length type)
            :append (expand-slot-to-layout 
                     (list (varjo:flesh-out-type 
                            (varjo:type-principle type))
                           normalise))))
        ((varjo:mat-typep type) 
         (loop for i below (varjo:mat/vec-length type)
            :append (expand-slot-to-layout 
                     (list (varjo:type-mat-col-to-vec type)
                           normalise))))
        ((varjo:vec-typep type) 
         `((,(varjo:mat/vec-length type) 
             ,(varjo:type-vec-core-type type) 
             ,normalise)))
        (t `((1 ,(varjo:type-principle type) ,normalise)))))))


(defun make-gl-struct-attrib-assigner (type-name slots)
  (when (every #'varjo:type-built-inp (mapcar #'slot-type slots))
    (let* ((stride (if (> (length slots) 1)
                       `(cffi:foreign-type-size '(:struct ,type-name))
                       0))
           (stride-sym (gensym "stride"))
           (definitions 
            (loop :for attr :in 
               (mapcan #'(lambda (x) (expand-slot-to-layout (subseq x 1))) 
                       slots)
               :for i :from 0
               :with offset = 0
               :append `((gl:enable-vertex-attrib-array (+ attrib-offset ,i))
                         (%gl:vertex-attrib-pointer 
                          (+ attrib-offset ,i) ,@attr ,stride-sym 
                          (cffi:make-pointer (+ ,offset pointer-offset))))
               :do (setf offset (+ offset 
                                   (* (first attr) 
                                      (cffi:foreign-type-size 
                                       (second attr)))))))) ; uhoh...how do we do this?
      (when definitions
        `(defmethod gl-assign-attrib-pointers 
             ((array-type (EQL ',type-name)) 
              &optional (attrib-offset 0) (pointer-offset 0) stride-override normalised)
           (declare (ignore array-type normalised))
           (let ((,stride-sym (or stride-override ,stride)))
             ,@definitions
             ,(length definitions)))))))

(defun make-cstruct-def (name slots)
  `(defcstruct ,name
     ,@(loop for slot in slots
          :collect 
            (list (slot-name slot)
                  (if (varjo:type-aggregate-p 
                       (varjo:type-principle (slot-type slot)))
                      `(:struct ,(agg-type-helper-name (slot-type slot)))
                      (let ((stype (varjo:type-principle (slot-type slot))))
                        (if (keywordp stype) stype `(:struct ,stype))))
                  :count (if (varjo:type-arrayp (slot-type slot))
                             (varjo:type-array-length 
                              (slot-type slot))
                             1)))))

(defun slot-name (slot) (first slot))
(defun slot-type (slot) (second slot))
(defun slot-normalisedp (slot) (third slot))


;; need options for:
;; * varjo-struct
;; * ptr-accessors 
;; * generic-accessors
;; * per slot choice, no accessor
;; * if cant have a setter then error at macro-time
;; * if one slot cant be set then no destructuring-populate
;; * special case for pointer types
(defmacro defglstruct (name &body slot-descriptions)
  ;; tidy up the slot definintions
  (let ((slots (loop for slot in slot-descriptions
                  collect (destructuring-bind 
                                (slot-name 
                                 slot-type 
                                 &key (normalised nil) 
                                 (accessor nil)
                                 &allow-other-keys)
                              slot
                            (list slot-name 
                                  (varjo:flesh-out-type slot-type) 
                                  normalised
                                  accessor))))
        (e-type `(:struct ,name)))
    
    ;; write the code
    `(progn
       (varjo:vdefstruct ,name
         ,@(loop for slot in slots
              collect (append (subseq slot 0 2) 
                              (list nil nil)
                              (last slot))))
       ,(make-cstruct-def name slots)
       (defclass ,(utils:symb name) (gl-struct-array) 
         ((type :initform ',name)))
       (defmethod make-gl-array ((element-type (eql 'name)) dimensions
                                 &optional initial-contents pointer
                                   (alignment 1))
         (let* ((byte-length (gl-calc-byte-size ',e-type dimensions
                                                alignment))
                (array (make-instance
                        ',name 
                        :type ',e-type
                        :pointer (or pointer (foreign-alloc :char 
                                                            :count byte-length))
                        :len (apply #'* dimensions)
                        :row-byte-size byte-length
                        :row-alignment alignment
                        :dimensions dimensions)))
           (when initial-contents (destructuring-populate array initial-contents))
           array))
       ,@(make-gl-struct-slot-getters name slots)
       ,@(make-gl-struct-slot-setters name slots)
       ,(make-gl-struct-dpop name slots)
       ,(make-gl-struct-glpull name slots)
       ,(make-gl-struct-attrib-assigner name slots)
       ',name)))