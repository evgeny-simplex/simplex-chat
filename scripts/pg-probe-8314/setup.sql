CREATE TABLE sx_directory_group_regs(
  group_reg_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  group_id BIGINT NOT NULL REFERENCES groups ON UPDATE RESTRICT ON DELETE CASCADE,
  user_group_reg_id BIGINT NOT NULL,
  contact_id BIGINT NOT NULL REFERENCES contacts(contact_id) ON UPDATE RESTRICT ON DELETE CASCADE,
  owner_member_id BIGINT REFERENCES group_members(group_member_id) ON UPDATE RESTRICT ON DELETE CASCADE,
  group_reg_status TEXT NOT NULL,
  group_promoted SMALLINT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);

CREATE UNIQUE INDEX idx_sx_directory_group_regs_group_id ON sx_directory_group_regs(group_id);
CREATE UNIQUE INDEX idx_sx_directory_group_regs_owner_member_id ON sx_directory_group_regs(owner_member_id);
CREATE UNIQUE INDEX idx_sx_directory_group_regs_owner_contact_id_user_group_reg_id ON sx_directory_group_regs(contact_id, user_group_reg_id);

CREATE SCHEMA probe;

CREATE FUNCTION probe.run_batch(stmts text[]) RETURNS double precision
LANGUAGE plpgsql
AS $$
DECLARE
  s text;
  t0 timestamptz := clock_timestamp();
BEGIN
  FOREACH s IN ARRAY stmts LOOP
    EXECUTE s;
  END LOOP;
  RETURN extract(epoch FROM clock_timestamp() - t0) * 1000;
END;
$$;
