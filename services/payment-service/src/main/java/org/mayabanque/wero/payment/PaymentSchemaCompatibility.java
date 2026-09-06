package org.mayabanque.wero.payment;

import io.agroal.api.AgroalDataSource;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import org.jboss.logging.Logger;

/**
 * Small compatibility migration for an existing V2/V5 lab database.
 *
 * Hibernate schema update does not widen an already-created PostgreSQL CHECK
 * constraint when a new Java enum value is introduced. B6 adds
 * RECOVERY_PENDING, so an existing CRC database can still reject the atomic
 * UNKNOWN -> RECOVERY_PENDING claim until the constraint is recreated.
 *
 * A PostgreSQL advisory transaction lock serializes the migration across the
 * two N+1 payment-service replicas.
 */
@ApplicationScoped
public class PaymentSchemaCompatibility {

    private static final Logger LOG = Logger.getLogger(PaymentSchemaCompatibility.class);
    private static final String REQUIRED_VALUE = "RECOVERY_PENDING";

    @Inject AgroalDataSource dataSource;

    void onStart(@Observes StartupEvent ignored) {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("select pg_advisory_xact_lock(hashtext('wero_payment_status_constraint_v6'))");

                if (!paymentsTableExists(statement)) {
                    connection.rollback();
                    LOG.warn("payments table not available; payment status compatibility migration skipped");
                    return;
                }

                String definition = currentConstraintDefinition(statement);
                if (definition != null && definition.contains(REQUIRED_VALUE)) {
                    connection.commit();
                    LOG.info("payments_status_check already accepts RECOVERY_PENDING");
                    return;
                }

                statement.executeUpdate("alter table payments drop constraint if exists payments_status_check");
                statement.executeUpdate("""
                        alter table payments
                        add constraint payments_status_check
                        check (status in (
                          'CREATED',
                          'PROCESSING',
                          'PENDING',
                          'SETTLED',
                          'FAILED',
                          'UNKNOWN',
                          'RECOVERY_PENDING'
                        ))
                        """);
                connection.commit();
                LOG.info("payments_status_check migrated to accept RECOVERY_PENDING");
            } catch (Exception e) {
                connection.rollback();
                throw e;
            }
        } catch (Exception e) {
            throw new IllegalStateException("Unable to migrate payments_status_check for B6 recovery", e);
        }
    }

    private static boolean paymentsTableExists(Statement statement) throws SQLException {
        try (ResultSet rs = statement.executeQuery("select to_regclass('public.payments') is not null")) {
            return rs.next() && rs.getBoolean(1);
        }
    }

    private static String currentConstraintDefinition(Statement statement) throws SQLException {
        try (ResultSet rs = statement.executeQuery("""
                select pg_get_constraintdef(oid)
                from pg_constraint
                where conrelid = 'payments'::regclass
                  and conname = 'payments_status_check'
                  and contype = 'c'
                """)) {
            return rs.next() ? rs.getString(1) : null;
        }
    }
}
