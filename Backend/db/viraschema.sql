-- =========================================================
-- VIRA GYM BOOKING SYSTEM — PostgreSQL Schema (3NF)
-- =========================================================

-- ---------- ENUM TYPES ----------
CREATE TYPE user_role AS ENUM ('member', 'admin', 'trainer_admin');
CREATE TYPE gender_type AS ENUM ('male', 'female', 'other');
CREATE TYPE pass_type AS ENUM ('weekly', 'biweekly', 'monthly', 'half_yearly', 'yearly');
CREATE TYPE activity_type AS ENUM ('yoga', 'zumba', 'dance', 'pilates', 'swimming', 'strength_training', 'cardio', 'crossfit', 'other');
CREATE TYPE booking_status AS ENUM ('booked', 'cancelled', 'completed', 'no_show');
CREATE TYPE payment_status AS ENUM ('pending', 'success', 'failed', 'refunded');
CREATE TYPE pay_method AS ENUM ('card', 'upi', 'cash', 'netbanking', 'wallet');
CREATE TYPE session_mode AS ENUM ('group', 'personal');

-- ---------- USERS ----------
CREATE TABLE users (
    user_id      SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    email        VARCHAR(150) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    phone        VARCHAR(15) UNIQUE NOT NULL,
    gender       gender_type,
    dob          DATE,
    role         user_role NOT NULL DEFAULT 'member',
    created_at   TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------- GYMS ----------
CREATE TABLE gyms (
    gym_id       SERIAL PRIMARY KEY,
    gym_name     VARCHAR(100) NOT NULL,
    address      VARCHAR(255) NOT NULL,
    city         VARCHAR(100) NOT NULL,
    contact_no   VARCHAR(15) NOT NULL
);

-- ---------- TRAINERS ----------
CREATE TABLE trainers (
    trainer_id     SERIAL PRIMARY KEY,
    gym_id         INT NOT NULL REFERENCES gyms(gym_id) ON DELETE CASCADE,
    full_name      VARCHAR(100) NOT NULL,
    gender         gender_type,
    speciality     activity_type NOT NULL,
    experience_yrs SMALLINT CHECK (experience_yrs >= 0),
    rating         NUMERIC(3,2) CHECK (rating BETWEEN 0 AND 5) DEFAULT 0
);

-- ---------- PASSES (membership) ----------
CREATE TABLE passes (
    pass_id      SERIAL PRIMARY KEY,
    user_id      INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    gym_id       INT NOT NULL REFERENCES gyms(gym_id) ON DELETE CASCADE,
    type         pass_type NOT NULL,
    price        NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    valid_from   DATE NOT NULL,
    valid_to     DATE NOT NULL CHECK (valid_to > valid_from)
);

-- ---------- SLOTS / SESSIONS (time-based, capacity-limited) ----------
CREATE TABLE slots (
    slot_id      SERIAL PRIMARY KEY,
    gym_id       INT NOT NULL REFERENCES gyms(gym_id) ON DELETE CASCADE,
    trainer_id   INT REFERENCES trainers(trainer_id) ON DELETE SET NULL,
    activity     activity_type NOT NULL,
    session_date DATE NOT NULL,
    start_time   TIME NOT NULL,
    duration_min SMALLINT NOT NULL CHECK (duration_min > 0),
    mode         session_mode NOT NULL DEFAULT 'group',
    capacity     SMALLINT NOT NULL CHECK (capacity > 0),
    available    SMALLINT NOT NULL CHECK (available >= 0),
    status       VARCHAR(20) NOT NULL DEFAULT 'open',
    UNIQUE (trainer_id, session_date, start_time)
);

-- ---------- BOOKINGS ----------
CREATE TABLE bookings (
    booking_id   SERIAL PRIMARY KEY,
    user_id      INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    slot_id      INT NOT NULL REFERENCES slots(slot_id) ON DELETE CASCADE,
    pass_id      INT NOT NULL REFERENCES passes(pass_id) ON DELETE RESTRICT,
    status       booking_status NOT NULL DEFAULT 'booked',
    booked_at    TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (user_id, slot_id)   -- prevents double-booking same slot
);

-- ---------- PAYMENTS ----------
CREATE TABLE payments (
    payment_id   SERIAL PRIMARY KEY,
    user_id      INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    booking_id   INT REFERENCES bookings(booking_id) ON DELETE SET NULL,
    pass_id      INT REFERENCES passes(pass_id) ON DELETE SET NULL,
    amount       NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
    pay_method   pay_method NOT NULL,
    status       payment_status NOT NULL DEFAULT 'pending',
    pay_date     TIMESTAMP NOT NULL DEFAULT now(),
    CHECK (booking_id IS NOT NULL OR pass_id IS NOT NULL) -- payment must link to something
);

-- ---------- REVIEWS ----------
CREATE TABLE reviews (
    review_id    SERIAL PRIMARY KEY,
    user_id      INT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    gym_id       INT NOT NULL REFERENCES gyms(gym_id) ON DELETE CASCADE,
    rating       NUMERIC(3,2) NOT NULL CHECK (rating BETWEEN 0 AND 5),
    comment      TEXT,
    review_date  TIMESTAMP NOT NULL DEFAULT now()
);

-- =========================================================
-- INDEXES
-- =========================================================
CREATE INDEX idx_trainers_gym        ON trainers(gym_id);
CREATE INDEX idx_passes_user         ON passes(user_id);
CREATE INDEX idx_passes_gym          ON passes(gym_id);
CREATE INDEX idx_slots_gym_date      ON slots(gym_id, session_date);
CREATE INDEX idx_slots_trainer       ON slots(trainer_id);
CREATE INDEX idx_bookings_user       ON bookings(user_id);
CREATE INDEX idx_bookings_slot       ON bookings(slot_id);
CREATE INDEX idx_payments_user       ON payments(user_id);
CREATE INDEX idx_reviews_gym         ON reviews(gym_id);

-- =========================================================
-- STORED PROCEDURE 1: book_slot (with capacity check)
-- =========================================================
CREATE OR REPLACE FUNCTION book_slot(
    p_user_id   INT,
    p_slot_id   INT
) RETURNS INT AS $$
DECLARE
    v_available  SMALLINT;
    v_gym_id     INT;
    v_session_dt DATE;
    v_pass_id    INT;
    v_booking_id INT;
BEGIN
    -- lock the slot row to prevent race conditions on concurrent bookings
    SELECT available, gym_id, session_date INTO v_available, v_gym_id, v_session_dt
    FROM slots
    WHERE slot_id = p_slot_id
    FOR UPDATE;

    IF v_available IS NULL THEN
        RAISE EXCEPTION 'Slot % does not exist', p_slot_id;
    END IF;

    IF v_available <= 0 THEN
        RAISE EXCEPTION 'Slot % is full', p_slot_id;
    END IF;

    -- user must hold a currently valid pass for this gym to book a session
    SELECT pass_id INTO v_pass_id
    FROM passes
    WHERE user_id = p_user_id
      AND gym_id = v_gym_id
      AND v_session_dt BETWEEN valid_from AND valid_to
    ORDER BY valid_to DESC
    LIMIT 1;

    IF v_pass_id IS NULL THEN
        RAISE EXCEPTION 'User % has no active pass for gym % on %', p_user_id, v_gym_id, v_session_dt;
    END IF;

    INSERT INTO bookings (user_id, slot_id, pass_id, status)
    VALUES (p_user_id, p_slot_id, v_pass_id, 'booked')
    RETURNING booking_id INTO v_booking_id;

    RETURN v_booking_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'User % already booked slot %', p_user_id, p_slot_id;
END;
$$ LANGUAGE plpgsql;

-- =========================================================
-- STORED PROCEDURE 2: cancel_booking
-- =========================================================
CREATE OR REPLACE FUNCTION cancel_booking(
    p_booking_id INT
) RETURNS VOID AS $$
DECLARE
    v_status booking_status;
BEGIN
    SELECT status INTO v_status FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Booking % does not exist', p_booking_id;
    END IF;

    IF v_status = 'cancelled' THEN
        RAISE EXCEPTION 'Booking % already cancelled', p_booking_id;
    END IF;

    UPDATE bookings SET status = 'cancelled' WHERE booking_id = p_booking_id;
END;
$$ LANGUAGE plpgsql;

-- =========================================================
-- TRIGGER: auto-update slot availability on booking insert/delete
-- (also handles status change to/from 'cancelled')
-- =========================================================
CREATE OR REPLACE FUNCTION update_slot_availability() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE slots SET available = available - 1 WHERE slot_id = NEW.slot_id;

    ELSIF TG_OP = 'DELETE' THEN
        UPDATE slots SET available = available + 1 WHERE slot_id = OLD.slot_id;

    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.status <> 'cancelled' AND NEW.status = 'cancelled' THEN
            UPDATE slots SET available = available + 1 WHERE slot_id = NEW.slot_id;
        ELSIF OLD.status = 'cancelled' AND NEW.status <> 'cancelled' THEN
            UPDATE slots SET available = available - 1 WHERE slot_id = NEW.slot_id;
        END IF;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_booking_availability
AFTER INSERT OR DELETE OR UPDATE ON bookings
FOR EACH ROW EXECUTE FUNCTION update_slot_availability();

-- =========================================================
-- TRIGGER: trainer speciality must match slot activity
-- =========================================================
CREATE OR REPLACE FUNCTION check_trainer_speciality() RETURNS TRIGGER AS $$
DECLARE
    v_speciality activity_type;
BEGIN
    IF NEW.trainer_id IS NULL THEN
        RETURN NEW; -- slot can be unassigned, allow it
    END IF;

    SELECT speciality INTO v_speciality
    FROM trainers
    WHERE trainer_id = NEW.trainer_id;

    IF v_speciality IS DISTINCT FROM NEW.activity THEN
        RAISE EXCEPTION 'Trainer % specializes in % but slot activity is %',
            NEW.trainer_id, v_speciality, NEW.activity;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trainer_speciality_match
BEFORE INSERT OR UPDATE ON slots
FOR EACH ROW EXECUTE FUNCTION check_trainer_speciality();