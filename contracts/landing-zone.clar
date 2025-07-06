;; Landing Zone Contract
;; Coordinates safe delivery locations

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u400))
(define-constant ERR_ZONE_NOT_FOUND (err u401))
(define-constant ERR_ZONE_UNAVAILABLE (err u402))
(define-constant ERR_INVALID_RESERVATION (err u403))
(define-constant ERR_RESERVATION_CONFLICT (err u404))
(define-constant ERR_INVALID_COORDINATES (err u405))

;; Data Variables
(define-data-var next-zone-id uint u1)
(define-data-var next-reservation-id uint u1)

;; Data Maps
(define-map landing-zones
  uint
  {
    zone-name: (string-ascii 100),
    latitude: int,
    longitude: int,
    altitude: uint,
    capacity: uint,
    zone-type: (string-ascii 20), ;; residential, commercial, emergency
    owner: principal,
    active: bool,
    access-fee: uint,
    security-level: uint
  }
)

(define-map zone-reservations
  uint
  {
    zone-id: uint,
    drone-id: (string-ascii 50),
    operator: principal,
    start-time: uint,
    end-time: uint,
    purpose: (string-ascii 50),
    status: (string-ascii 20),
    fee-paid: uint
  }
)

(define-map zone-availability
  uint
  {
    zone-id: uint,
    current-occupancy: uint,
    last-updated: uint,
    maintenance-mode: bool,
    weather-restricted: bool
  }
)

(define-map zone-access-permissions
  { zone-id: uint, operator: principal }
  {
    permission-level: uint, ;; 1=basic, 2=priority, 3=emergency
    granted-by: principal,
    granted-at: uint,
    expires-at: uint,
    active: bool
  }
)

(define-map zone-usage-history
  uint
  {
    zone-id: uint,
    total-landings: uint,
    successful-deliveries: uint,
    last-maintenance: uint,
    average-duration: uint,
    safety-incidents: uint
  }
)

;; Public Functions

;; Register new landing zone
(define-public (register-landing-zone (zone-name (string-ascii 100)) (latitude int) (longitude int)
                                     (altitude uint) (capacity uint) (zone-type (string-ascii 20)) (access-fee uint))
  (let ((zone-id (var-get next-zone-id)))
    (asserts! (and (>= latitude -9000000) (<= latitude 9000000)
                   (>= longitude -18000000) (<= longitude 18000000)) ERR_INVALID_COORDINATES)
    (asserts! (and (> capacity u0) (> altitude u0)) ERR_INVALID_COORDINATES)

    (map-set landing-zones zone-id
      {
        zone-name: zone-name,
        latitude: latitude,
        longitude: longitude,
        altitude: altitude,
        capacity: capacity,
        zone-type: zone-type,
        owner: tx-sender,
        active: true,
        access-fee: access-fee,
        security-level: u1
      }
    )

    (map-set zone-availability zone-id
      {
        zone-id: zone-id,
        current-occupancy: u0,
        last-updated: block-height,
        maintenance-mode: false,
        weather-restricted: false
      }
    )

    (map-set zone-usage-history zone-id
      {
        zone-id: zone-id,
        total-landings: u0,
        successful-deliveries: u0,
        last-maintenance: block-height,
        average-duration: u0,
        safety-incidents: u0
      }
    )

    (var-set next-zone-id (+ zone-id u1))
    (ok zone-id)
  )
)

;; Make reservation
(define-public (make-reservation (zone-id uint) (drone-id (string-ascii 50)) (start-time uint)
                                (end-time uint) (purpose (string-ascii 50)))
  (let ((zone (unwrap! (map-get? landing-zones zone-id) ERR_ZONE_NOT_FOUND))
        (availability (unwrap! (map-get? zone-availability zone-id) ERR_ZONE_NOT_FOUND))
        (reservation-id (var-get next-reservation-id)))
    (asserts! (get active zone) ERR_ZONE_UNAVAILABLE)
    (asserts! (not (get maintenance-mode availability)) ERR_ZONE_UNAVAILABLE)
    (asserts! (> end-time start-time) ERR_INVALID_RESERVATION)
    (asserts! (< (get current-occupancy availability) (get capacity zone)) ERR_ZONE_UNAVAILABLE)

    ;; Check for reservation conflicts (simplified)
    (asserts! (is-ok (check-reservation-conflicts zone-id start-time end-time)) ERR_RESERVATION_CONFLICT)

    (map-set zone-reservations reservation-id
      {
        zone-id: zone-id,
        drone-id: drone-id,
        operator: tx-sender,
        start-time: start-time,
        end-time: end-time,
        purpose: purpose,
        status: "confirmed",
        fee-paid: (get access-fee zone)
      }
    )

    (var-set next-reservation-id (+ reservation-id u1))
    (ok reservation-id)
  )
)

;; Check in to landing zone
(define-public (check-in-landing-zone (reservation-id uint))
  (let ((reservation (unwrap! (map-get? zone-reservations reservation-id) ERR_INVALID_RESERVATION))
        (zone-id (get zone-id reservation))
        (availability (unwrap! (map-get? zone-availability zone-id) ERR_ZONE_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get operator reservation)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status reservation) "confirmed") ERR_INVALID_RESERVATION)

    (map-set zone-reservations reservation-id
      (merge reservation { status: "active" })
    )

    (map-set zone-availability zone-id
      (merge availability
        {
          current-occupancy: (+ (get current-occupancy availability) u1),
          last-updated: block-height
        }
      )
    )

    (ok true)
  )
)

;; Check out from landing zone
(define-public (check-out-landing-zone (reservation-id uint) (delivery-successful bool))
  (let ((reservation (unwrap! (map-get? zone-reservations reservation-id) ERR_INVALID_RESERVATION))
        (zone-id (get zone-id reservation))
        (availability (unwrap! (map-get? zone-availability zone-id) ERR_ZONE_NOT_FOUND))
        (usage-history (unwrap! (map-get? zone-usage-history zone-id) ERR_ZONE_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get operator reservation)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status reservation) "active") ERR_INVALID_RESERVATION)

    (map-set zone-reservations reservation-id
      (merge reservation { status: "completed" })
    )

    (map-set zone-availability zone-id
      (merge availability
        {
          current-occupancy: (- (get current-occupancy availability) u1),
          last-updated: block-height
        }
      )
    )

    (map-set zone-usage-history zone-id
      (merge usage-history
        {
          total-landings: (+ (get total-landings usage-history) u1),
          successful-deliveries: (if delivery-successful
                                   (+ (get successful-deliveries usage-history) u1)
                                   (get successful-deliveries usage-history))
        }
      )
    )

    (ok true)
  )
)

;; Grant access permission
(define-public (grant-access-permission (zone-id uint) (operator principal) (permission-level uint) (expires-at uint))
  (let ((zone (unwrap! (map-get? landing-zones zone-id) ERR_ZONE_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get owner zone)) ERR_UNAUTHORIZED)
    (asserts! (and (>= permission-level u1) (<= permission-level u3)) ERR_INVALID_RESERVATION)
    (asserts! (> expires-at block-height) ERR_INVALID_RESERVATION)

    (map-set zone-access-permissions { zone-id: zone-id, operator: operator }
      {
        permission-level: permission-level,
        granted-by: tx-sender,
        granted-at: block-height,
        expires-at: expires-at,
        active: true
      }
    )

    (ok true)
  )
)

;; Set maintenance mode
(define-public (set-maintenance-mode (zone-id uint) (maintenance-mode bool))
  (let ((zone (unwrap! (map-get? landing-zones zone-id) ERR_ZONE_NOT_FOUND))
        (availability (unwrap! (map-get? zone-availability zone-id) ERR_ZONE_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get owner zone)) ERR_UNAUTHORIZED)

    (map-set zone-availability zone-id
      (merge availability
        {
          maintenance-mode: maintenance-mode,
          last-updated: block-height
        }
      )
    )

    (ok true)
  )
)

;; Read-only Functions

;; Get landing zone
(define-read-only (get-landing-zone (zone-id uint))
  (map-get? landing-zones zone-id)
)

;; Get zone availability
(define-read-only (get-zone-availability (zone-id uint))
  (map-get? zone-availability zone-id)
)

;; Get reservation
(define-read-only (get-reservation (reservation-id uint))
  (map-get? zone-reservations reservation-id)
)

;; Get zone usage history
(define-read-only (get-zone-usage-history (zone-id uint))
  (map-get? zone-usage-history zone-id)
)

;; Check access permission
(define-read-only (check-access-permission (zone-id uint) (operator principal))
  (match (map-get? zone-access-permissions { zone-id: zone-id, operator: operator })
    permission (and (get active permission) (> (get expires-at permission) block-height))
    false
  )
)

;; Check zone availability
(define-read-only (is-zone-available (zone-id uint))
  (match (map-get? zone-availability zone-id)
    availability (and
                   (< (get current-occupancy availability)
                      (default-to u0 (get capacity (map-get? landing-zones zone-id))))
                   (not (get maintenance-mode availability))
                   (not (get weather-restricted availability)))
    false
  )
)

;; Check reservation conflicts (simplified)
(define-read-only (check-reservation-conflicts (zone-id uint) (start-time uint) (end-time uint))
  (ok true) ;; Simplified implementation - would check against existing reservations
)
