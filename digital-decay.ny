;nyquist plug-in
;version 4
;type process
;name "Digital Decay"
;author "RedMoth and Gemini"
;release "1.0.0"
;copyright "Released under terms of the MIT License"
;codetype lisp
;preview linear
;debugbutton false

;; --- MAIN UI PARAMETERS ---
;control bitrate "Bitrate" float "kbps" 320.0 2.0 320.0
;control loss-prob "Packet Loss" float "%" 0.0 0.0 100.0
;control max-chunk-ms "Max Packet Size" float "ms" 50.0 10.0 500.0
;control jitter-ms "Jitter Buffer" float "ms" 26.0 5.0 100.0
;control loss-mode "Loss Mode" choice "Silence,PLC Smooth,Repeat,Random" 1
;control bw-index "Bandwidth" choice "Auto,4 kHz,6 kHz,8 kHz,12 kHz,20 kHz" 0
;control phone-srate "Device Sample Rate" float "Hz" 41000.0 1000.0 48000.0
;control disorder "Packet Disorder" float "%" 0.0 0.0 100.0
;control stutter-prob "Extra Stutter" float "%" 0.0 0.0 100.0
;control noise-amt "Noise Amount" float "%" 0.0 0.0 100.0
;control noise-col "Noise Color" float "%" 0.0 -100.0 100.0
;control crunch-gain "Crunch Gain" float "dB" 0.0 0.0 12.0
;control crunch-freq "Crunch Frequency" float "Hz" 150.0 20.0 20000.0
;control crunch-width "Crunch Width" float "oct" 1.0 0.1 2.0
;control crush-prob "Payload Crush" float "%" 0.0 0.0 100.0
;control crush-bits "Crush Resolution" int "bits" 4 2 16
;control mix "Dry / Wet Mix" float "%" 100.0 0.0 100.0

;; --- DECIMATION (SAMPLE RATE REDUCTION) ---
(defun apply-decimation (sig target-hz)
  (if (>= target-hz *sound-srate*)
      sig
      ;; Hacks the Nyquist engine to compress and re-expand the frequency,
      ;; creating aliasing and "hardware" artifacts.
      (force-srate *sound-srate* (force-srate target-hz sig))))

;; --- COLORED NOISE GENERATOR ---
(defun generate-colored-noise (len amt col)
  (if (<= amt 0.0)
      (s-rest len)
      (let* ((n (extract-abs 0 len (noise)))
             (scaled-n (mult n (* 0.5 (/ amt 100.0))))
             (filtered-n
              (cond
                ((< col 0)
                 ;; Lowpass filter for deep tape-like rumble
                 (lp scaled-n (+ 100.0 (* (/ (+ col 100.0) 100.0) 9900.0))))
                ((> col 0)
                 ;; Highpass filter for sharp digital hiss
                 (hp scaled-n (+ 100.0 (* (/ col 100.0) 7900.0))))
                (t scaled-n))))
        filtered-n)))

;; --- MP3 ARTIFACTS AND BANDWIDTH LIMITER ---
(defun get-cutoff (br)
  (cond ((<= br 8) 2500.0) ((<= br 16) 3000.0) ((<= br 24) 3500.0)
        ((<= br 32) 4000.0) ((<= br 48) 6000.0) ((<= br 64) 8000.0)
        ((<= br 96) 12000.0) (t 16000.0)))

(defun get-bandwidth (bw-idx br)
  (cond ((= bw-idx 1) 4000.0) ((= bw-idx 2) 6000.0) ((= bw-idx 3) 8000.0)
        ((= bw-idx 4) 12000.0) ((= bw-idx 5) 20000.0) (t (get-cutoff br))))

(defun get-preecho (br)
  (cond ((<= br 8) 100.0)
        ((<= br 32) (+ 30.0 (* (/ (- 32.0 br) 24.0) 70.0)))
        (t (* (/ (- 128.0 br) 96.0) 30.0))))

(defun apply-mp3-artifacts (sig br len-sec)
  (let* ((cutoff (get-bandwidth bw-index (float br)))
         (preecho (get-preecho (float br)))
         (filtered (lowpass8 (lowpass8 sig cutoff) cutoff))
         (delay-sec (* 0.02 (/ preecho 100.0)))
         (delayed (if (> delay-sec 0) (abs-env (at delay-sec (cue filtered))) filtered))
         (mixed (sim (mult 0.4 filtered) (mult 0.8 delayed)))
         (bit-depth (max 10 (min 16 (+ 10 (* (/ (float br) 128.0) 6)))))
         (quant-steps (truncate (power 2 bit-depth))))
    (extract-abs 0 len-sec (quantize mixed quant-steps))))

;; --- CORE NETWORK ENGINE ---
(defun process-network-stereo (snd-array)
  (let* ((chunk-max-sec (/ max-chunk-ms 1000.0))
         (len-sec (get-duration 1))
         (jitter-sec (/ jitter-ms 1000.0))
         (fade-sec 0.1)
         (l-do '()) (l-fade-do '()) (l-n '()) (l-s '()) (l-c '()) (l-d '()) (l-fade-stut '())
         (t-curr 0.0))

    (if (< chunk-max-sec 0.005) (setf chunk-max-sec 0.005))

    ;; 1. DISORDER & ANTI-CLICK MAP
    (let ((t-do 0.0)
          (prev-delay (if (< (real-random 0 100) disorder) (* jitter-sec (if (< (real-random 0 100) 50) 1.0 2.0)) 0.0)))

      (push prev-delay l-do)
      (push 1.0 l-fade-do)

      (do () ((>= t-do len-sec))
        (let* ((step (real-random 0.015 chunk-max-sec))
               (t-next (min (+ t-do step) len-sec))
               (dice (real-random 0 100))
               (delay-val (if (< dice disorder) (* jitter-sec (if (< (real-random 0 100) 50) 1.0 2.0)) 0.0)))

          (if (and (< t-next len-sec) (not (= prev-delay delay-val)))
              (let ((t-f-start (max t-do (- t-next 0.005)))
                    (t-f-end   (min len-sec (+ t-next 0.005))))
                (push t-next l-do) (push prev-delay l-do)
                (push t-next l-do) (push delay-val l-do)
                (push t-f-start l-fade-do) (push 1.0 l-fade-do)
                (push t-next l-fade-do) (push 0.0 l-fade-do)
                (push t-f-end l-fade-do) (push 1.0 l-fade-do))
              (progn
                (push t-next l-do) (push prev-delay l-do)
                (push t-next l-fade-do) (push 1.0 l-fade-do)))

          (setf prev-delay delay-val)
          (setf t-do t-next))))

    ;; 2. PACKET LOSS & PLC STUTTER MAP
    (push 0.0 l-d)
    (do () ((>= t-curr len-sec))
      (let* ((step (real-random 0.005 chunk-max-sec))
             (t-next (min (+ t-curr step) len-sec))
             (dice (real-random 0 100))
             (is-drop nil) (is-stut nil) (is-crush nil) (is-norm nil))

        (cond
          ((< dice loss-prob) (setf is-drop t))
          ((< dice (+ loss-prob stutter-prob)) (setf is-stut t))
          ((< dice (+ loss-prob stutter-prob crush-prob)) (setf is-crush t))
          (t (setf is-norm t)))

        (let ((ns (if is-norm 1.0 0.0)) (cs (if is-crush 1.0 0.0)) (ce (if is-crush 1.0 0.0)))
          (when (= t-curr 0.0)
            (push ns l-n)
            (push (if (or is-drop is-stut) 1.0 0.0) l-s)
            (push cs l-c)
            (push 1.0 l-fade-stut))

          (when (> t-curr 0.0)
            (let ((t-f (min (+ t-curr 0.005) t-next)))
              (push t-f l-n) (push ns l-n)
              (push t-f l-c) (push cs l-c)))
          (push t-next l-n) (push ns l-n)
          (push t-next l-c) (push ce l-c)

          (if is-drop
            (let ((m loss-mode))
              (if (= m 3) (setf m (if (< (real-random 0 100) 50) 1 2)))
              (cond
                ((= m 1)
                 (let* ((actual-fade (min fade-sec (- t-next t-curr)))
                        (t-mid (+ t-curr (* actual-fade 0.33)))
                        (t-end (+ t-curr actual-fade)))
                   (when (> t-curr 0.0) (push t-curr l-s) (push 1.0 l-s))
                   (if (> actual-fade 0.001) (progn (push t-mid l-s) (push 0.3 l-s)))
                   (push t-end l-s) (push 0.0 l-s)
                   (if (< t-end t-next) (progn (push t-next l-s) (push 0.0 l-s)))))
                ((= m 2)
                 (when (> t-curr 0.0) (push (min (+ t-curr 0.005) t-next) l-s) (push 1.0 l-s))
                 (push t-next l-s) (push 1.0 l-s))
                (t
                 (when (> t-curr 0.0) (push (min (+ t-curr 0.005) t-next) l-s) (push 0.0 l-s))
                 (push t-next l-s) (push 0.0 l-s))))
            (progn
              (when (> t-curr 0.0) (push (min (+ t-curr 0.005) t-next) l-s) (push (if is-stut 1.0 0.0) l-s))
              (push t-next l-s) (push (if is-stut 1.0 0.0) l-s)))

          (if (or is-drop is-stut)
              (let ((drift (real-random 0.98 1.02)))
                (do ((t-m t-curr (+ t-m jitter-sec))
                     (d-m jitter-sec (+ d-m jitter-sec)))
                    ((>= t-m t-next))
                  (let* ((t-m-next (min (+ t-m jitter-sec) t-next))
                         (t-dip-end (min (+ t-m 0.005) t-m-next)))
                    (when (> t-m 0.0)
                      (push t-m l-d) (push d-m l-d)
                      (push t-m l-fade-stut) (push 0.0 l-fade-stut)
                      (push t-dip-end l-fade-stut) (push 1.0 l-fade-stut))
                    (push t-m-next l-d) (push (* d-m drift) l-d)
                    (push t-m-next l-fade-stut) (push 1.0 l-fade-stut))))
              (progn
                (when (> t-curr 0.0)
                  (push t-curr l-d) (push 0.0 l-d)
                  (push (min (+ t-curr 0.005) t-next) l-fade-stut) (push 1.0 l-fade-stut))
                (push t-next l-d) (push 0.0 l-d)
                (push t-next l-fade-stut) (push 1.0 l-fade-stut)))

          (setf t-curr t-next))))

    ;; 3. FINAL VECTOR ASSEMBLY
    (let* ((env-do (control-srate-abs *sound-srate* (abs-env (pwlv-list (reverse l-do)))))
           (env-fade-do (control-srate-abs *sound-srate* (abs-env (pwlv-list (reverse l-fade-do)))))
           (env-norm (control-srate-abs *sound-srate* (abs-env (pwlv-list (reverse l-n)))))
           (env-stut (control-srate-abs *sound-srate* (abs-env (pwlv-list (reverse l-s)))))
           (env-crush (control-srate-abs *sound-srate* (abs-env (pwlv-list (reverse l-c)))))
           (env-delay (control-srate-abs *sound-srate* (abs-env (pwlv-list (reverse l-d)))))
           (env-fade-stut (control-srate-abs *sound-srate* (abs-env (pwlv-list (reverse l-fade-stut))))))

      (defun process-single-channel (ch-snd)
        (let* ((decimated-snd (apply-decimation ch-snd phone-srate))
               (noise-sig (generate-colored-noise len-sec noise-amt noise-col))

               (pre-codec-sig (sim decimated-snd noise-sig))

               (mp3-sig (apply-mp3-artifacts pre-codec-sig bitrate len-sec))
               (mp3-disordered (mult env-fade-do (snd-tapv mp3-sig 0.0 env-do (+ (* jitter-sec 3) 0.1))))

               (sig-norm mp3-disordered)
               (sig-stut (mult env-fade-stut (lp (snd-tapv mp3-disordered 0.0 env-delay (+ chunk-max-sec jitter-sec 0.1)) 3000)))
               (sig-crush (quantize mp3-disordered (truncate (power 2 crush-bits))))

               (glitched-sig (extract-abs 0 len-sec
                               (sim (mult sig-norm env-norm)
                                    (mult sig-stut env-stut)
                                    (mult sig-crush env-crush))))

               ;; --- DYNAMIC CRUNCH SECTION ---
               (crunched-sig (if (<= crunch-gain 0.0)
                                 glitched-sig
                                 (let* ((eq-sig (eq-band glitched-sig crunch-freq crunch-gain (max 0.1 crunch-width)))
                                        (env (lp (snd-abs eq-sig) 20))
                                        (duck-gain (recip (sim 1.0 (mult env 1.5))))
                                        (choked-sig (mult eq-sig duck-gain))
                                        (final-crunch (clip choked-sig 0.95)))
                                   final-crunch)))

               (wet-vol (/ mix 100.0))
               (dry-vol (- 1.0 wet-vol)))

          (sim (mult ch-snd dry-vol) (mult crunched-sig wet-vol))))

      (if (arrayp snd-array)
          (vector (process-single-channel (aref snd-array 0))
                  (process-single-channel (aref snd-array 1)))
          (process-single-channel snd-array)))))

(process-network-stereo *track*)
