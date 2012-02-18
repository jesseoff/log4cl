(in-package :log4cl)

(defvar *watcher-thread-bindings* `((*debug-io* . ,*debug-io*)))

(defun start-hierarchy-watcher-thread ()
  (unless *watcher-thread*
    (let ((logger (make-logger '(log4cl))))
      (bordeaux-threads:make-thread
       (lambda ()
         ;; prevent two watcher threads from being started due to race
         (when (with-recursive-lock-held (*hierarchy-lock*)
                 (cond (*watcher-thread*
                        (log-debug "Watcher thread already started")
                        nil)
                       (t (setq *watcher-thread* (bt:current-thread)))))
           (unwind-protect
                (handler-case 
                    (progn
                      (log-info logger "Hierarchy watcher started")
                      (loop
                        (hierarchy-watcher-once)
                        (sleep *hierarchy-watcher-heartbeat*)))
                  (error (e)
                    (log-error logger "Error in hierarchy watcher thread:~%~A" e)))
             (with-recursive-lock-held (*hierarchy-lock*)
               (setf *watcher-thread* nil))
             (log-info logger "Hierarchy watcher thread ended"))))
       :name "Hierarchy Watcher"
       :initial-bindings
       `((*hierarchy* . 0)
         ,@*watcher-thread-bindings*
         ,@bordeaux-threads:*standard-io-bindings*)))))


(defun hierarchy-watcher-do-one-token (hier token)
  (with-slots (watch-tokens name) hier
    (with-log-hierarchy (hier)
      (handler-bind ((serious-condition
                       (lambda (c)
                         (setf watch-tokens (remove token watch-tokens))
                         (log-error
                          '(log4cl)
                          "WATCH-TOKEN-CHECK in ~S hierarchy signaled error for token ~S~%~A"
                          name token c)
                         (return-from hierarchy-watcher-do-one-token))))
        (watch-token-check token)))))

(defun hierarchy-watcher-once ()
  "Do one iteration of watcher loop."
  (map nil
       (lambda (hier)
         (dolist (token (slot-value hier 'watch-tokens))
           (hierarchy-watcher-do-one-token hier token)))
       *hierarchies*))

(defun stop-hierarchy-watcher-thread ()
  (when *watcher-thread*
    (bt::destroy-thread *watcher-thread*)))
