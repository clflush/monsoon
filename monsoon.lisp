;; a binary rainfall visualizer for data (esp. packets)
;; 0 = red, 1 = green, 2 = blue

(in-package :monsoon)

(defvar +red+ 0)
(defvar +green+ 1)
(defvar +blue+ 2)

(defun asciip (b)
  (or (< #x07 b #x0E) (< #x1F b #x80)))


(defun %heatmap-row (buffer caplen width row)
  (let ((shade-r (ceiling (* 16 (/ 256 caplen))))
        (shade-g (ceiling (* 8 (/ 256 caplen))))
        (interval (* 3 (floor (/ width 256 3)))))
    (loop for b across (subseq buffer 0 caplen) do
      (let ((fill-r (min #xFF
                         (+ shade-r
                            (aref row (+ (* b interval) +red+)))))
            (fill-g (min #xFF
                         (+ shade-g
                            (aref row (+ (* b interval) +green+))))))
        (loop for i
              from (* b interval)
                to (1- (* (1+ b) interval))
              by 3
              do
                 (setf (aref row (+ i +red+))
                       fill-r)
                 (setf (aref row (+ i +green+))
                       fill-g))))
    ;; blue lines demarcating ascii region
    (when *highlight-ascii*
      (setf (aref row (+ (* #x0A interval) +red+)) #xFF)
      (setf (aref row (+ (* #x80 interval) +red+)) #xFF))

    row))

(defun %bitwise-row (buffer caplen width row)
  (loop for i below (floor (/ width 9)) do
    (let ((ascii (in-string-p buffer caplen i))
          (the-byte (if (>= i caplen)
                        0
                        (aref buffer i))))
      (loop for j from 8 downto 0
            with interval = (* i 9)
            do
               (cond ((= j 8)
                      (setf (aref row
                                  (+ +green+
                                     (* (+ interval  j) 3)))
                            #x20))
                     ((setf (aref row
                                  (+ (if ascii +red+ +blue+)
                                     (* (+ interval j) 3)))
                            (if (zerop
                                 (ldb (byte 1 (- 7 j))
                                      the-byte))
                                #x00
                                #xFF)))))))
  row)

(defun in-string-p (buffer caplen index)
  (and *highlight-ascii*
       (< index caplen)
       (or  (every #'asciip
                   (loop for j below *ascii-len*
                         collect
                         (aref buffer
                               (min (1- caplen)
                                    (+ j index)))))
            (every #'asciip
                   (loop for j below *ascii-len*
                         collect
                         (aref buffer
                               (max 0
                                    (- index j))))))))

(defun make-row (buffer caplen width)
  (let ((row (make-array (* width 3) :element-type '(unsigned-byte 8)
                                     :initial-element 0)))
    (case *mode*
      ((:bitwise) (%bitwise-row buffer caplen width row))
      ((:heatmap) (%heatmap-row buffer caplen width row))
      (otherwise (%byte-row buffer caplen width row)))
    row))

(defun %byte-row (buffer caplen width row)
  (loop for i below width do
    (let* ((pixel (if (>= i caplen)
                      0
                      (aref buffer i)))
           (ascii (in-string-p buffer caplen i)))
      (if ascii
          (setf (aref row (+ +red+ (* i 3))) (logior #x80 pixel))
          (setf (aref row (+ +green+ (* i 3))) pixel))))
  row)

(defun scan-row (width)
  (let ((row (make-array (* width 3) :element-type '(unsigned-byte 8)
                                     :initial-element 0)))
    (loop for i below width do
      (setf (aref row (+ +blue+ (* i 3))) #xFF))
    row))

(defun write-row (path buffer caplen counter height width header-len)
  (let ((offset (+ header-len
                   (* (mod counter height) width 3)))
        (row (make-row buffer caplen width)))
    (with-open-file (stream path :direction :output
                                 :element-type '(unsigned-byte 8)
                                 :if-exists :overwrite)
      (file-position stream offset)
      (write-sequence row stream)
      (write-sequence (scan-row width) stream))
    row))

(defun color-offset (arr i color-idx)
  (aref arr (+ color-idx (* i 3))))

(defun sdl-color-from-row (row i)
  (sdl:color :r (color-offset row i +red+)  
             :g (color-offset row i +green+)
             :b (color-offset row i +blue+)))

(defun show-row (buffer caplen counter height width)
  (let ((y (mod counter height))
        (x 0)
        (xe 0)
        (scanrow (sdl:color :r #xFF :b #x00 :g #xFF))
        (row (make-row buffer caplen width)))
    (loop while (< xe width) do
      (let ((color (sdl-color-from-row row x)))
        (loop repeat *thickness* do
          (loop repeat *thickness*
                with ye = y do
            (sdl:draw-pixel-* xe (mod ye height)
                              :color (sdl-color-from-row row x))
            (incf ye))
          (sdl:draw-pixel-* xe (mod (+ y *thickness*) height)
                            :color scanrow)
          (incf xe))
        (sdl:free color)
        (incf x)))
    (sdl:free scanrow)))

(defun sniff (pcap-path image-path interface
              &key (snaplen 512)
                (rotate-at 512)
                (count 512)
                (promisc t)
                (packets nil)
                (filter nil))
  (let ((counter 0)
        (imagebuffer (make-array (* snaplen rotate-at 3)
                                 :element-type '(unsigned-byte 8)))
        (header-len (prepare-canvas image-path rotate-at snaplen)))
    (with-pcap-interface (pcap interface :promisc promisc
                                         :snaplen snaplen
                                         :nbio t)
      (with-pcap-writer (writer pcap-path :snaplen snaplen
                                          :datalink (pcap-live-datalink pcap))
        (when filter
          (set-filter pcap filter))
        (loop
          (when (and packets (> counter packets))
            return)
          (capture pcap 64
                   (lambda (sec usec caplen len buffer)
                     (dump writer buffer sec usec :length caplen :origlength len)
                     (write-row image-path
                                buffer
                                caplen
                                counter
                                rotate-at
                                snaplen
                                header-len)
                     (incf counter)
                     (format t "[~D] Packet length: ~A bytes (~A), on the wire: ~A bytes~%" counter caplen (length buffer) len)))
          (sleep 0.001))))))


(defun vid-sniff (&key
                    (interface *interface*)
                    (image-path *image-path*)
                    (pcap-path *pcap-path*)
                    (snaplen (video-width :init t))
                    (rotate-at  (video-height :init t))
                    (promisc *promiscuous*)
                    (filter *filter*))
  (let ((counter 0)
        (header-len (when image-path
                      (prepare-canvas image-path rotate-at snaplen))))
    (with-graphics (:width snaplen
                    :height rotate-at
                    :frame-rate -1
                    :flags (list sdl:sdl-resizable))

      (with-pcap-interface (pcap interface :promisc promisc
                                           :snaplen (video-width); snaplen
                                           :nbio t)
        (with-pcap-writer (writer pcap-path :snaplen #x10000 ;snaplen
                                            :datalink (pcap-live-datalink pcap))
          (when filter
            (set-filter pcap filter))
          (frame-loop ()
              (capture pcap *rate*
                       (lambda (sec usec caplen len buffer)
                         (dump writer buffer sec usec
                               :length caplen
                               :origlength len)
                           (show-row buffer
                                     caplen
                                     counter
                                     (video-height)
                                     (video-width))
                           (when image-path
                             (write-row image-path
                                        buffer
                                        caplen
                                        counter
                                        rotate-at
                                        snaplen
                                        header-len))
                           (incf counter *thickness*)
                         (when *debug*
                           (format t "[~D] Packet length: ~A bytes (~A), on the wire: ~A bytes~%" counter caplen (length buffer) len))))
            (sleep 0.01)))))))

