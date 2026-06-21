-- ============================================================
-- GYM PASS & SESSION BOOKING SYSTEM — PostgreSQL Schema (3NF)
-- Derived from hand-drawn ERD: USER, TRAINER, GYM, PASS,
-- SESSION, PAYMENT, REVIEW (+ session_booking bridge, see note)
-- ============================================================

CREATE TYPE gender_type      AS ENUM ('male', 'female', 'other');
CREATE TYPE pass_type        AS ENUM ('monthly', 'quarterly', 'annual', 'day_pass');
CREATE TYPE session_mode     AS ENUM ('online', 'offline');
CREATE TYPE session_status   AS ENUM ('scheduled', 'completed', 'cancelled');
CREATE TYPE booking_status   AS ENUM ('booked', 'cancelled', 'attended', 'no_show');
CREATE TYPE payment_status   AS ENUM ('pending', 'success', 'failed', 'refunded');
CREATE TYPE pay_method_type  AS ENUM ('card', 'upi', 'wallet', 'cash', 'netbanking');

-- ---------- USER ----------
CREATE TABLE users (
    user_id         BIGSERIAL PRIMARY KEY,
    full_name       VARCHAR(120) NOT NULL,
    email           VARCHAR(255) NOT NULL UNIQUE,
    password_hash   TEXT NOT NULL,
    phone           VARCHAR(20)  NOT NULL UNIQUE,
    dob             DATE,
    gender          gender_type,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- GYM ----------
CREATE TABLE gyms (
    gym_id          BIGSERIAL PRIMARY KEY,
    gym_name        VARCHAR(150) NOT NULL,
    address         VARCHAR(255) NOT NULL,
    city            VARCHAR(100) NOT NULL,
    contact_no      VARCHAR(20) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_gyms_city ON gyms(city);

-- ---------- TRAINER ----------
CREATE TABLE trainers (
    trainer_id      BIGSERIAL PRIMARY KEY,
    gym_id          BIGINT NOT NULL REFERENCES gyms(gym_id) ON DELETE CASCADE, -- EMPLOYS
    full_name       VARCHAR(120) NOT NULL,
    speciality      VARCHAR(100),
    gender          gender_type,
    experience_yrs  INT CHECK (experience_yrs >= 0),
    rating          NUMERIC(2,1) CHECK (rating BETWEEN 0 AND 5),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_trainers_gym ON trainers(gym_id);

-- ---------- PASS ----------
-- purchased by a user; "generates" sessions
CREATE TABLE passes (
    pass_id         BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(user_id), -- purchase: 1 user -> N passes
    type            pass_type NOT NULL,
    price           NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    valid_from      DATE NOT NULL,
    valid_to        DATE NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_pass_validity CHECK (valid_to > valid_from)
);

CREATE INDEX idx_passes_user ON passes(user_id);
CREATE INDEX idx_passes_validity ON passes(valid_from, valid_to);

-- ---------- SESSION ----------
-- generated from a pass; held at a gym; conducted by a trainer; capacity-limited
CREATE TABLE sessions (
    session_id      BIGSERIAL PRIMARY KEY,
    pass_id         BIGINT NOT NULL REFERENCES passes(pass_id) ON DELETE CASCADE, -- generates
    gym_id          BIGINT NOT NULL REFERENCES gyms(gym_id),                      -- held_at
    trainer_id      BIGINT REFERENCES trainers(trainer_id) ON DELETE SET NULL,    -- conducts
    session_date    DATE NOT NULL,
    duration_mins   INT NOT NULL CHECK (duration_mins > 0),
    mode            session_mode NOT NULL DEFAULT 'offline',
    status          session_status NOT NULL DEFAULT 'scheduled',
    capacity        INT NOT NULL CHECK (capacity > 0),
    booked_count    INT NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_session_overbook CHECK (booked_count <= capacity)
);

CREATE INDEX idx_sessions_gym_date ON sessions(gym_id, session_date);
CREATE INDEX idx_sessions_trainer ON sessions(trainer_id);
CREATE INDEX idx_sessions_pass ON sessions(pass_id);

-- ---------- SESSION_BOOKING (bridge, see note above) ----------
-- links a user (pass-holder) to a session they attend; enforces capacity
CREATE TABLE session_bookings (
    booking_id      BIGSERIAL PRIMARY KEY,
    session_id      BIGINT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    user_id         BIGINT NOT NULL REFERENCES users(user_id),
    status          booking_status NOT NULL DEFAULT 'booked',
    booked_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancelled_at    TIMESTAMPTZ,
    CONSTRAINT chk_cancel_consistency CHECK (
        (status = 'cancelled' AND cancelled_at IS NOT NULL) OR
        (status <> 'cancelled' AND cancelled_at IS NULL)
    )
);

CREATE UNIQUE INDEX uq_active_booking_per_user_session
    ON session_bookings(session_id, user_id)
    WHERE status = 'booked';

CREATE INDEX idx_bookings_user ON session_bookings(user_id);
CREATE INDEX idx_bookings_session ON session_bookings(session_id);

-- ---------- PAYMENT ----------
-- a user makes a payment, tied to the pass purchased
CREATE TABLE payments (
    payment_id      BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(user_id), -- makes
    pass_id         BIGINT NOT NULL UNIQUE REFERENCES passes(pass_id) ON DELETE CASCADE,
    amount          NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
    status          payment_status NOT NULL DEFAULT 'pending',
    pay_method      pay_method_type NOT NULL,
    pay_date        TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_payments_user ON payments(user_id);
CREATE INDEX idx_payments_status ON payments(status);

-- ---------- REVIEW ----------
-- a user writes a review about a gym
CREATE TABLE reviews (
    review_id       BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(user_id), -- write
    gym_id          BIGINT NOT NULL REFERENCES gyms(gym_id),
    rating          NUMERIC(2,1) NOT NULL CHECK (rating BETWEEN 0 AND 5),
    comment         TEXT,
    review_date     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_user_gym_review UNIQUE (user_id, gym_id) -- one review per user per gym
);

CREATE INDEX idx_reviews_gym ON reviews(gym_id);

-- ============================================================
-- TRIGGER: auto-maintain sessions.booked_count
-- ============================================================
CREATE OR REPLACE FUNCTION trg_fn_update_session_count()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status = 'booked' THEN
            UPDATE sessions SET booked_count = booked_count + 1 WHERE session_id = NEW.session_id;
        END IF;
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        IF OLD.status = 'booked' THEN
            UPDATE sessions SET booked_count = booked_count - 1 WHERE session_id = OLD.session_id;
        END IF;
        RETURN OLD;

    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.status = 'booked' AND NEW.status <> 'booked' THEN
            UPDATE sessions SET booked_count = booked_count - 1 WHERE session_id = OLD.session_id;
        ELSIF OLD.status <> 'booked' AND NEW.status = 'booked' THEN
            UPDATE sessions SET booked_count = booked_count + 1 WHERE session_id = NEW.session_id;
        END IF;
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_session_booking_count_change
AFTER INSERT OR UPDATE OR DELETE ON session_bookings
FOR EACH ROW EXECUTE FUNCTION trg_fn_update_session_count();

-- ============================================================
-- PROCEDURE: book_slot (books a session, capacity-checked)
-- ============================================================
CREATE OR REPLACE PROCEDURE book_slot(
    p_user_id    BIGINT,
    p_session_id BIGINT,
    OUT p_booking_id BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_booked   INT;
    v_has_valid_pass BOOLEAN;
BEGIN
    -- lock the session row to prevent race conditions on concurrent bookings
    SELECT capacity, booked_count
      INTO v_capacity, v_booked
      FROM sessions
     WHERE session_id = p_session_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Session % does not exist', p_session_id;
    END IF;

    IF v_booked >= v_capacity THEN
        RAISE EXCEPTION 'Session % is fully booked (capacity %)', p_session_id, v_capacity;
    END IF;

    -- user must hold a currently-valid pass to book
    SELECT EXISTS (
        SELECT 1 FROM passes p
         WHERE p.user_id = p_user_id
           AND CURRENT_DATE BETWEEN p.valid_from AND p.valid_to
    ) INTO v_has_valid_pass;

    IF NOT v_has_valid_pass THEN
        RAISE EXCEPTION 'User % has no active pass', p_user_id;
    END IF;

    INSERT INTO session_bookings (session_id, user_id, status)
    VALUES (p_session_id, p_user_id, 'booked')
    RETURNING booking_id INTO p_booking_id;

    -- booked_count increment happens automatically via trigger
END;
$$;

-- Usage:
-- CALL book_slot(12, 304, NULL);

-- ============================================================
-- PROCEDURE: cancel_booking
-- ============================================================
CREATE OR REPLACE PROCEDURE cancel_booking(
    p_booking_id BIGINT,
    p_user_id    BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status booking_status;
    v_owner  BIGINT;
BEGIN
    SELECT status, user_id INTO v_status, v_owner
      FROM session_bookings
     WHERE booking_id = p_booking_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking % does not exist', p_booking_id;
    END IF;

    IF v_owner <> p_user_id THEN
        RAISE EXCEPTION 'User % is not authorized to cancel booking %', p_user_id, p_booking_id;
    END IF;

    IF v_status = 'cancelled' THEN
        RAISE EXCEPTION 'Booking % is already cancelled', p_booking_id;
    END IF;

    UPDATE session_bookings
       SET status = 'cancelled',
           cancelled_at = now()
     WHERE booking_id = p_booking_id;

    -- booked_count decrement happens automatically via trigger
END;
$$;

-- Usage:
-- CALL cancel_booking(55, 12);