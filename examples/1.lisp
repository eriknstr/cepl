;; This is simply to get a colored triangle up on the screen

(in-package :cepl-examples)

(defparameter *prog-1* nil)
(defparameter *shaders* nil)
(defparameter *streams* nil)

(cgl:define-interleaved-attribute-format vert-data 
  (:index 0 :type :float :components (x y z w))
  (:index 1 :type :float :components (r g b a)))

(defun init () 
  (setf *shaders* 
	(mapcar #'cgl:make-shader `("1.vert" "1.frag")))
  (setf *prog-1* (cgl:make-program *shaders*))
  (setf *streams* 
	(list (cgl::make-gl-stream 
	       :vao (cgl:make-vao 
		     (cgl:gen-buffer 
		      :initial-contents 
		      (cgl:destructuring-allocate 
		       'vert-data  
		       '((( 0.0     0.5  0.0  1.0)
			  ( 1.0     0.0  0.0  1.0))
			 (( 0.5  -0.366  0.0  1.0)
			  ( 0.0     1.0  0.0  1.0))
			 ((-0.5  -0.366  0.0  1.0)
			  ( 0.0     0.0  1.0  1.0))))))
	       :length 3))))

(defun reshape (width height)  
  (gl:viewport 0 0 width height))

(defun draw ()
  (cgl::clear-color 0.0 0.0 0.0 0.0)
  (cgl::clear :color-buffer-bit)
  (funcall *prog-1* *streams*)
  (gl:flush)
  (sdl:update-display))

(defun run-demo () 
  (init-sdl ()
    (init)
    (reshape 640 480)
    (sdl:with-events () 
      (:quit-event () t)
      (:VIDEO-RESIZE-EVENT (:w width :h height) 
			   (reshape width height))
      (:idle ()
	     (base-macros:continuable (cepl-utils:update-swank))
	     (base-macros:continuable (draw))))))