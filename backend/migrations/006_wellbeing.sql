CREATE TABLE app.wellbeing_journal (
    user_id uuid NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    day date NOT NULL,
    mood text NOT NULL CHECK(mood IN ('calm','happy','tired','sad','anxious')),
    note text NOT NULL DEFAULT '' CHECK(char_length(note)<=500),
    PRIMARY KEY(user_id,day)
);

CREATE TABLE app.wellbeing_sleep (
    user_id uuid NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    day date NOT NULL,
    minutes_after_midnight int NOT NULL CHECK(minutes_after_midnight BETWEEN 0 AND 1439),
    PRIMARY KEY(user_id,day)
);
