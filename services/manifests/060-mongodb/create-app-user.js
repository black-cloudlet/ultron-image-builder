// The image's entrypoint runs this once, on an empty /data/db, against a
// temporary mongod on 127.0.0.1 with auth off, right after it creates root
// from MONGO_INITDB_ROOT_*. It never runs again: a later password lives only
// in the database (rotation is changeUserPassword, see passwords.yaml).
// readWriteAnyDatabase: every database's data and indexes, nothing of
// users, roles, server settings or shutdown, which stay root's.
// The trailing-newline strip matches how the entrypoint reads root's file.
db.getSiblingDB('admin').createUser({
  user: 'app',
  pwd: fs.readFileSync('/run/mongodb-passwords/app', 'utf8').replace(/\n+$/, ''),
  roles: [{ role: 'readWriteAnyDatabase', db: 'admin' }],
});
