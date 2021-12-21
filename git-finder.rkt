#lang racket

(require racket/os)

(define-struct/contract Local
  ([hostname string?]
   [path path-string?]
   [description (or/c #f string?)])
  #:transparent)

(define locals? (listof Local?))

;; TODO Consider making Remote a child of Local
(define-struct/contract Remote
  ([hostname string?]
   [address string?])
  #:transparent)

(define remotes? (listof Remote?))

(define-struct/contract Repo
  ([root string?]
   [locals locals?] ; TODO locals should be a custom set keyed on hostname+path
   [remotes remotes?])
  #:transparent)

(define/contract (exe cmd)
  (-> string? (listof string?))
  (match-define
    (list stdout stdin _pid stderr ctrl)
    (process cmd))
  (define lines (port->lines stdout))
  (ctrl 'wait)
  (match (ctrl 'status)
    ['done-ok (void)]
    ['done-error
     (copy-port stderr (current-error-port))
     (exit 1)])
  (close-output-port stdin)
  (close-input-port stdout)
  (close-input-port stderr)
  lines)

(define/contract (git-dir->remotes git-dir-path)
  (-> path-string? (listof string?))
  (exe
    (string-append
      "git --git-dir=" git-dir-path " remote -v | awk '{print $2}' | sort -u")))

(define/contract (git-dir->root-digest git-dir-path)
  (-> path-string? (or/c #f string?))
  (define cmd
    (string-append
      "git --git-dir=" git-dir-path " log --pretty=oneline --reverse | head -1 | awk '{print $1}'"))
  (match (exe cmd)
    ['() #f]
    [(list digest) digest]
    [_ (assert-unreachable)]))

(define/contract (find-git-dirs search-paths)
  (-> (listof path-string?) (listof path-string?))
  (define (find search-path)
    (exe (string-append "find " search-path " -type d -name .git")))
  (append* (map find search-paths)))

(define uniq
  (compose set->list list->set))

(define/contract (find-git-repos hostname search-paths exclude-prefix exclude-regexp)
  (-> string? (listof path-string?) (listof path-string?) (listof pregexp?) (listof Repo?))
  (define (root repos) (first (first repos))) ; All roots are the same in a group
  (define (locals repos) (map second repos))
  (define (remotes repos) (uniq (append* (map third repos))))
  (map (λ (repos-with-shared-root-commit)
          (Repo (root repos-with-shared-root-commit)
                (map (λ (path-git)
                        (define path-description (build-path path-git "description"))
                        (define description
                          (if (file-exists? path-description)
                              (match (file->lines path-description)
                                ['() #f]
                                [(list* line _)
                                 (if (string-prefix? line "Unnamed repository;")
                                     #f
                                     line)])
                              #f))
                        (Local hostname path-git description))
                     (locals repos-with-shared-root-commit))
                (map (λ (addr) (Remote hostname addr))
                     (remotes repos-with-shared-root-commit))))
       (group-by first
                 (foldl (λ (dir repos)
                           ; TODO git lookups can be done concurrently
                           (match (git-dir->root-digest dir)
                             [#f repos]
                             [root
                               (define remotes (git-dir->remotes dir))
                               (define repo (list root dir remotes))
                               (cons repo repos)]))
                        '()
                        (filter
                          (λ (path)
                             (and (not (ormap (curry string-prefix? path)
                                              exclude-prefix))
                                  (not (ormap (λ (px) (regexp-match? px path))
                                              exclude-regexp))))
                          (find-git-dirs search-paths))))))

(define/contract (print-table repos)
  (-> (listof Repo?) void?)
  (define (output root tag get-host get-addr locations)
    (for-each
      (λ (l) (displayln (string-join (list root (get-host l) tag (get-addr l)) " ")))
      locations))
  (for-each
    (λ (repo)
       (match-define (Repo root locals remotes) repo)
       (output root "local"  Local-hostname  Local-path     locals)
       (output root "remote" Remote-hostname Remote-address remotes)
       (newline) ; So that same-root locations are visually grouped.
       )
    repos))

(define/contract (print-graph repos)
  (-> (listof Repo?) void?)
  (define all-roots (mutable-set))
  (define all-locals (mutable-set))
  (define all-remotes (mutable-set))
  (define (local-id l) (format "~a:~a" (Local-hostname l) (Local-path l)))
  (define (local-label l)
    (define description (Local-description l))
    (define path (Local-path l))
    (if description
        (format "~a~n~a" path description)
        (format "~a"     path)))
  (displayln "digraph {")
  (for-each
    (λ (r)
       ; TODO Color and shape codes for: root, local and remote.
       (match r
         [(Repo root (and locals (list* _ _ _)) remotes)
          (for-each
            (λ (l)
               (set-add! all-roots root)
               (set-add! all-locals l)
               (printf
                 "~v -> ~v [label=~v, fontname=monospace, fontsize=8];~n"
                 root
                 (local-id l)
                 (Local-hostname l)))
            locals)
          (for-each
            (λ (r)
               (set-add! all-roots root)
               (set-add! all-remotes r)
               (printf
                 "~v -> ~v [label=~v, fontname=monospace, fontsize=8];~n"
                 root
                 (Remote-address r)
                 (Remote-hostname r)))
            remotes)]
         [_ (void)]))
    repos)
  (set-for-each
    all-roots
    (λ (r)
       (printf
         "~v [shape=point style=filled, fillcolor=yellowgreen fontcolor=white, fontname=monospace, fontsize=8];~n"
         r)))
  (set-for-each
    all-locals
    (λ (l)
       (printf
         "~v [label=~v shape=folder, style=filled, fillcolor=wheat, fontname=monospace, fontsize=8];~n"
         (local-id l)
         (local-label l))))
  (set-for-each
    all-remotes
    (λ (r)
       (printf
         "~v [shape=oval, style=filled, fillcolor=lightblue, fontname=monospace, fontsize=8];~n"
         (Remote-address r))))
  (displayln "}"))

(module+ main
  ; TODO handle sub commands:
  ; - TODO "collect" data for current host
  ; - TODO "integrate" data from per-host data files into a graphviz file

  (let ([out-format 'table]
        [exclude-prefix (mutable-set)]
        [exclude-regexp (mutable-set)])
    (command-line
      #:program "git-finder"

      #:once-any
      [("-t" "--table")
       "All found repos in a tabular text format."
       (set! out-format 'table)]
      [("-g" "--graph-dupes")
       "Multi-homed repos in DOT language for Graphviz."
       (set! out-format 'graph)]

      #:multi
      [("-e" "--exclude-prefix")
       directory "Directory subtree prefix to exclude the found candidate paths."
       (invariant-assertion path-string? directory)
       (set-add! exclude-prefix directory)]
      [("-x" "--exclude-regexp")
       perl-like-regexp "Pattern to exclude from the found candidate paths."
       (let ([px (pregexp perl-like-regexp (λ (err-msg) err-msg))])
         (invariant-assertion pregexp? px)
         (set-add! exclude-regexp px))]

      #:args search-paths
      (invariant-assertion (listof path-string?) search-paths)

      (define output
        (case out-format
          [(table) print-table]
          [(graph) print-graph]))
      (define t0 (current-inexact-milliseconds))
      (define repos
        (find-git-repos (gethostname)
                        search-paths
                        (set->list exclude-prefix)
                        (set->list exclude-regexp)))
      (output repos)
      (define t1 (current-inexact-milliseconds))
      (eprintf "Found ~a roots, ~a locals and ~a remotes in ~a seconds.~n"
               (length repos)
               (length (uniq (append* (map Repo-locals repos))))
               (length (uniq (append* (map Repo-remotes repos))))
               (real->decimal-string (/ (- t1 t0) 1000) 3)))))