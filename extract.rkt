#lang racket/base

(require db
         gregor
         net/url
         racket/cmdline
         racket/file
         racket/list
         racket/port
         racket/string
         tasks
         threading)

(define (get-cnt)
  (~> (string->url "https://www.optionseducation.org/toolsoptionquotes/optionsquotes")
      (get-pure-port _)
      (port->string _)
      (regexp-match #rx"cnt=([A-F0-9]+)" _)
      (second _)))

(define cnt (get-cnt))

(define (download-options-chains symbol cnt)
  (make-directory* (string-append "/var/tmp/oic/options-chains/" (~t (today) "yyyy-MM-dd")))
  (call-with-output-file (string-append "/var/tmp/oic/options-chains/" (~t (today) "yyyy-MM-dd") "/" symbol ".html")
    (λ (out) (with-handlers ([exn:fail?
                              (λ (error)
                                (displayln (string-append "Encountered error for " symbol))
                                (displayln ((error-value->string-handler) error 1000)))])
               (~> (string-append "https://oic.ivolatility.com/oic_adv_options.j?cnt=" cnt
                                  "&ticker=" (string-replace symbol "." "/") "&exp_date=-1")
                   (string->url _)
                   (get-pure-port _)
                   (copy-port _ out))))
    #:exists 'replace))

(define db-user (make-parameter "user"))

(define db-name (make-parameter "local"))

(define db-pass (make-parameter ""))

(define first-symbol (make-parameter ""))

(define last-symbol (make-parameter ""))

(command-line
 #:program "racket extract.rkt"
 #:once-each
 [("-f" "--first-symbol") first
                          "First symbol to query. Defaults to nothing"
                          (first-symbol first)]
 [("-l" "--last-symbol") last
                         "Last symbol to query. Defaults to nothing"
                         (last-symbol last)]
 [("-n" "--db-name") name
                     "Database name. Defaults to 'local'"
                     (db-name name)]
 [("-p" "--db-pass") password
                     "Database password"
                     (db-pass password)]
 [("-u" "--db-user") user
                     "Database user name. Defaults to 'user'"
                     (db-user user)])

(define dbc (postgresql-connect #:user (db-user) #:database (db-name) #:password (db-pass)))

(define symbols (query-list dbc "
select
  component_symbol as symbol
from
  spdr.etf_holding
where
  etf_symbol in ('SPY', 'MDY', 'SLY') and
  date = (select max(date) from spdr.etf_holding) and
  case when $1 != ''
    then component_symbol >= $1
    else true
  end and
  case when $2 != ''
    then component_symbol <= $2
    else true
  end
union
select distinct
  etf_symbol as symbol
from
  spdr.etf_holding
where
  date = (select max(date) from spdr.etf_holding) and
  case when $1 != ''
    then etf_symbol >= $1
    else true
  end and
  case when $2 != ''
    then etf_symbol <= $2
    else true
  end
union
select distinct
  component_symbol as symbol
from
  invesco.etf_holding
where
  date = (select max(date) from invesco.etf_holding) and
  case when $1 != ''
    then component_symbol >= $1
    else true
  end and
  case when $2 != ''
    then component_symbol <= $2
    else true
  end
union
select
  'BYND' as symbol
order by
  symbol;
"
                            (first-symbol)
                            (last-symbol)))

(disconnect dbc)

(define delay-interval 10)

(define delays (map (λ (x) (* delay-interval x)) (range 0 (length symbols))))

(with-task-server (for-each (λ (l) (schedule-delayed-task (λ () (cond [(= 0 (modulo (second l) 3600))
                                                                       (set! cnt (get-cnt))])
                                                            (download-options-chains (first l) cnt))
                                                          (second l)))
                            (map list symbols delays))
  ; add a final task that will halt the task server
  (schedule-delayed-task (λ () (schedule-stop-task)) (* delay-interval (length delays)))
  (run-tasks))
