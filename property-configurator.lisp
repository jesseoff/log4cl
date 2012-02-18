(in-package :log4cl)

(defclass property-configurator (property-parser)
  ((loggers)
   (additivity)
   (appenders))
  (:documentation "Class that holds configurator state while parsing
  the properties file"))

(defmethod shared-initialize :after ((config property-configurator) slots &rest initargs &key)
  (declare (ignore initargs))
  (with-slots (loggers additivity appenders)
      config
    (setf loggers '() additivity '() appenders '())))

(defclass logger-record (property-location)
  ((logger :initarg :logger)
   (level :initarg :level)
   (appender-names :initform nil :initarg :appender-names)))

(defclass delayed-instance (property-location)
  ((class :initform nil)
   (properties :initform nil)
   (extra-initargs :initform nil)
   (instance :initform nil)))

(defclass delayed-layout (delayed-instance)
  ((name :initarg :name)))

(defclass delayed-appender (delayed-instance)
  ((layout :initform nil)
   (name :initarg :name)
   (used :initform nil)))

(defmethod parse-property-keyword ((parser property-configurator)
                                   keyword
                                   tokens
                                   value)
  "Ignores anything that does not start with LOG4CL prefix, otherwise
calls PARSE-PROPERTY-TOKENS again (which will convert 2nd level of the
token name into the keyword and call this function again"
  (when (eq keyword :log4cl)
    (parse-property-tokens parser tokens value)))


(defun parse-logger-helper (parser keyword tokens value)
  "Common helper that handles both .rootLogger= and .logger.name=
  lines"
  (with-slots (name-token-separator name-token-read-case loggers)
      parser
    (let ((logger
            (cond ((eq keyword :rootLogger)
                   (or (null tokens)
                       (error "Root logger cannot have any sub-properties"))
                   *root-logger*)
                  (t (or tokens (error "Logger name missing"))
                     (get-logger-internal
                      tokens name-token-separator name-token-read-case))))
          (value-tokens (split-string value "," t)))
      (unless (plusp (length value-tokens))
        (error "Expecting LEVEL, [<APPENDER> ...] as the value"))
      (setf loggers (delete logger loggers :key #'car))
      (push (cons logger
                  (make-instance 'logger-record
                   :logger logger
                   :level (log-level-from-object (first value-tokens) *package*)
                   :appender-names (rest value-tokens)))
            loggers))))

(defmethod parse-property-keyword ((parser property-configurator)
                                   (keyword (eql :rootLogger))
                                   tokens
                                   value)
  (parse-logger-helper parser keyword tokens value))


(defmethod parse-property-keyword ((parser property-configurator)
                                   (keyword (eql :logger))
                                   tokens
                                   value)
  (parse-logger-helper parser keyword tokens value))


(defun intern-boolean (value)
  "Parse boolean value"
  (setq value (strip-whitespace value))
  (cond ((zerop (length value))
         nil)
        ((char= (char value 0) #\#)
         nil)
        ((member value '("nil" "none" "false" "off") :test 'equalp)
         nil)
        ((member value '("t" "true" "yes" "on") :test 'equalp)
         t)
        (t (error "Invalid boolean value ~s" value))))

(defmethod parse-property-keyword ((parser property-configurator)
                                   (keyword (eql :additivity))
                                   tokens
                                   value)
  (with-slots (name-token-separator name-token-read-case additivity)
      parser
    (or tokens
        (error "Missing logger name"))
    (let* ((logger
             (if (equalp tokens '("rootLogger"))
                 *root-logger*
                 (get-logger-internal
                  tokens name-token-separator name-token-read-case))))
      (setf additivity (delete logger additivity :key #'car))
      (push (cons logger (intern-boolean value))
            additivity))))

(defun intern-class-name (string)
  (let ((pos (position #\Colon string)))
    (if (null pos)
        (find-symbol string)
        (let ((pkg (find-package (substr string 0 pos)))
              (only-external-p t))
          (when pkg
            (incf pos)
            (when (and (< pos (length string))
                       (char= (char string pos) #\Colon))
              (incf pos)
              (setf only-external-p nil))
            (multiple-value-bind (symbol visibility)
                (find-symbol (substr string pos))
              (and (or (not only-external-p)
                       (equal visibility :external))
                   symbol)))))))

(defun set-delayed-instance-class (instance value)
  (with-slots (class name) instance
    (let ((new-class (intern-class-name value)))
      (or (null class) (error "~a class specified twice" name))
      (or new-class (error "~a class ~s not found" name value))
      (setf class new-class))))

(defun set-delayed-instance-property (instance tokens value)
  (with-slots (name properties)
      instance
    (let ((prop (intern (pop tokens) :keyword)))
      (or (null tokens) (error "~a expecting a single property" name))
      (or (null (assoc prop properties))
          (error "~a property ~s specified twice" name prop))
      (push (list prop value (make-instance 'property-location)) properties))))

(defmethod parse-property-keyword ((parser property-configurator)
                                   (keyword (eql :appender))
                                   tokens
                                   value)
  (with-slots (name-token-separator name-token-read-case appenders)
      parser
    (when (null tokens)
      (error "appender should be followed by appender name"))
    (let* ((name (pop tokens))
           (appender (or (cdr (assoc name appenders :test 'equal))
                         (cdar (push (cons
                                      name
                                      (make-instance 'delayed-appender
                                       :name (format nil "appender ~A" name)))
                                     appenders)))))
      (with-slots (class layout initargs)
          appender
        (cond ((null tokens)
               (set-delayed-instance-class
                appender (convert-read-case
                          (strip-whitespace value) name-token-read-case)))
              ((equal (first tokens) (symbol-name :layout))
               (pop tokens)
               (or layout
                   (setf layout (make-instance 'delayed-layout
                                 :name
                                 (format nil "~A's appender layout"
                                         name))))
               (if (null tokens)
                   (set-delayed-instance-class
                    layout (convert-read-case
                            (strip-whitespace value) name-token-read-case))
                   (set-delayed-instance-property layout tokens value)))
              (t (set-delayed-instance-property appender tokens value)))))))


(defun create-delayed-instance (instance)
  "First filter all properties through through INSTANCE-PROPERTY-FROM-STRING,
and then create the instance"
  (with-property-location (instance)
    (with-slots (instance name class properties extra-initargs)
        instance
      (setf instance
            (make-instance (or class (error "Class not specified for ~a" name))))
      ;; need to do it twice to apply properties, since property parsing
      ;; stuff is specialized on the instance class
      (setf instance (apply #'reinitialize-instance
                            instance
                            (append
                             (loop for (prop value location) in properties
                                   appending
                                      (with-property-location (location)
                                        (list prop (property-initarg-from-string
                                                    instance prop value))))
                             extra-initargs))))))

(defmethod parse-property-stream :after ((configurator property-configurator) stream)
  "Parse the stream and apply changes to logging configuration"
  (with-log-indent ()
    (with-slots (appenders loggers additivity)
        configurator
      ;; for each logger, see that logger's in appender list were defined
      (loop for (logger . rec) in loggers
            do (with-property-location (rec)
                 (log-sexp rec %parse-line %parse-line-num)
                 (dolist (name (slot-value rec 'appender-names))
                   (or (assoc name appenders :test 'equal)
                       (error "Logger ~a refers to non-existing appender ~s"
                              logger name))
                   (setf (slot-value (cdr (assoc name appenders :test 'equal))
                                     'used) t))))
      ;; create the appenders, we do this before mucking with loggers,
      ;; in case creating an appender singals an error
      (loop for (name . a) in appenders
            if (slot-value a 'used)
            do (with-slots (layout extra-initargs) a
                 (when layout
                   (setf extra-initargs
                         `(:layout ,(create-delayed-instance layout))))
                 (create-delayed-instance a)))
      (loop for (logger . rec) in loggers do
               (progn
                 (log-sexp "Doing " logger (slot-value rec 'level))
                 (when (assoc logger additivity)
                   (set-additivity logger (cdr (assoc logger additivity)) nil))
                 (remove-all-appenders-internal logger nil)
                 (set-log-level logger (slot-value rec 'level) nil)
                 (dolist (name (slot-value rec 'appender-names))
                   (add-appender-internal
                    logger (slot-value (cdr (assoc name appenders :test 'equal))
                                       'instance)
                    nil))
                 (adjust-logger logger))))))

(defmethod property-initarg-from-string (instance property value)
  "Generic implementation for numbers, boolean and string properties,
that calls PROPERTY-INITARG-ALIST function to determine what kind of
property it is. Signals error if property is not in the list"
  (let* ((props-alist (property-initarg-alist instance))
         (type (cdr (assoc property props-alist))))
    (case type
      (number (parse-integer (strip-whitespace value)))
      (boolean (intern-boolean (strip-whitespace value)))
      (string value)
      (t (error "Unknown property ~s for class ~s" property instance)))))

(defgeneric configure (configurator source &key &allow-other-keys)
  (:documentation "Configure the logging system from specified source"))

(defmethod configure ((configurator property-configurator)
                      (s stream) &key)
  "Configures logging from the specified stream"
  (parse-property-stream configurator s))

(defclass property-configurator-file-watch ()
  ((filespec :initarg :filespec :accessor filespec-of)
   (time :initarg :time)
   (configurator :initarg :configurator)))

(defmethod print-object ((watch property-configurator-file-watch) stream)
  (print-unreadable-object (watch stream :type t)
    (prin1 (slot-value watch 'filespec) stream)))

(defmethod configure ((configurator property-configurator) filespec &key auto-reload)
  "Configures logging from the specified file. If AUTO-RELOAD is
non-NIL, then after initial configuration will watch the file for
modifications and re-configure when it changes. Note that auto-reload
will not be configured if initial configuration signaled a error"
  (let ((filespec (merge-pathnames filespec)))
    (with-open-file (s filespec)
      (configure configurator s))
    (when auto-reload
      (with-slots (watch-tokens) (aref *hierarchies* *hierarchy*)
        (unless (find filespec watch-tokens :test #'equal :key #'filespec-of)
          (push (make-instance 'property-configurator-file-watch
                 :filespec filespec
                 :time (file-write-date filespec)
                 :configurator configurator)
                watch-tokens))))))

(defmethod watch-token-check ((token property-configurator-file-watch))
  "Checks properties file write time, and re-configure from it if it changed.
Catches and does not re-signal PROPERTY-PARSER-ERROR, so watching the
file continues if newly modified file had an error"
  (with-slots (filespec time configurator) token
    (let ((new-time (file-write-date filespec)))
      (when (/= new-time time)
        (setf time new-time)
        (log-info '(log4cl) "Re-configuring logging from changed file ~A" filespec)
        (handler-case
            (configure configurator filespec)
          (property-parser-error (c)
            (log-error '(log4cl)
                       "Configuration from file ~A failed:~%~A"
                       filespec c)))))))