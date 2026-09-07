package org.mayabanque.wero.payment;

import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.TraceFlags;
import io.opentelemetry.api.trace.TraceState;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import io.quarkus.scheduler.Scheduled;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Optional;
import java.util.Properties;
import java.util.concurrent.TimeUnit;
import org.apache.kafka.clients.CommonClientConfigs;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.config.SaslConfigs;
import org.apache.kafka.common.config.SslConfigs;
import org.apache.kafka.common.serialization.StringSerializer;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class OutboxPublisher {

    private static final Logger LOG = Logger.getLogger(OutboxPublisher.class);

    @ConfigProperty(name = "kafka.bootstrap.servers") String bootstrapServers;
    @ConfigProperty(name = "kafka.security.protocol", defaultValue = "PLAINTEXT") String securityProtocol;
    @ConfigProperty(name = "kafka.sasl.mechanism") Optional<String> saslMechanism;
    @ConfigProperty(name = "kafka.sasl.jaas.config") Optional<String> saslJaasConfig;
    @ConfigProperty(name = "kafka.ssl.truststore.type") Optional<String> sslTruststoreType;
    @ConfigProperty(name = "kafka.ssl.truststore.location") Optional<String> sslTruststoreLocation;
    @ConfigProperty(name = "wero.events.topic", defaultValue = "payment-events") String topic;
    @ConfigProperty(name = "wero.outbox.batch-size", defaultValue = "50") int batchSize;

    @Inject OutboxStore store;

    KafkaProducer<String, String> producer;

    @PostConstruct
    void init() {
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.ACKS_CONFIG, "all");
        props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");
        props.put(ProducerConfig.CLIENT_ID_CONFIG, "mayabanque-payment-outbox");
        applyKafkaSecurity(props);
        producer = new KafkaProducer<>(props);
    }

    private void applyKafkaSecurity(Properties props) {
        props.put(CommonClientConfigs.SECURITY_PROTOCOL_CONFIG, securityProtocol);
        saslMechanism.filter(v -> !v.isBlank()).ifPresent(v -> props.put(SaslConfigs.SASL_MECHANISM, v));
        saslJaasConfig.filter(v -> !v.isBlank()).ifPresent(v -> props.put(SaslConfigs.SASL_JAAS_CONFIG, v));
        sslTruststoreType.filter(v -> !v.isBlank()).ifPresent(v -> props.put(SslConfigs.SSL_TRUSTSTORE_TYPE_CONFIG, v));
        sslTruststoreLocation.filter(v -> !v.isBlank()).ifPresent(v -> props.put(SslConfigs.SSL_TRUSTSTORE_LOCATION_CONFIG, v));
    }

    @PreDestroy
    void close() {
        if (producer != null) producer.close();
    }

    @Scheduled(every = "1s", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    void publishBatch() {
        // Never hold a JTA/Hibernate transaction while waiting on Kafka network I/O.
        // DB reads and acknowledgements are committed in short transactions by OutboxStore.
        List<OutboxStore.PendingEvent> pending = store.loadPending(batchSize);

        for (OutboxStore.PendingEvent row : pending) {
            Context parent = parentContext(row.traceparent());
            Span span = GlobalOpenTelemetry.getTracer("mayabanque-outbox")
                    .spanBuilder("payment-events publish")
                    .setSpanKind(SpanKind.PRODUCER)
                    .setParent(parent)
                    .startSpan();
            span.setAttribute("messaging.system", "kafka");
            span.setAttribute("messaging.destination.name", topic);
            span.setAttribute("wero.payment_id", row.aggregateId());
            span.setAttribute("wero.event_id", row.eventId());
            if (row.correlationId() != null) span.setAttribute("wero.correlation_id", row.correlationId());

            try (Scope ignored = span.makeCurrent()) {
                // paymentId is the Kafka record key, preserving per-payment ordering
                // when payment-events is partitioned across the HA cluster.
                ProducerRecord<String, String> record = new ProducerRecord<>(topic, row.aggregateId(), row.payload());
                String outgoingTraceparent = traceparent(span.getSpanContext());
                if (outgoingTraceparent != null) {
                    record.headers().add("traceparent", outgoingTraceparent.getBytes(StandardCharsets.UTF_8));
                }
                if (row.correlationId() != null) {
                    record.headers().add("X-Correlation-Id", row.correlationId().getBytes(StandardCharsets.UTF_8));
                }

                producer.send(record).get(3, TimeUnit.SECONDS);
                store.markPublished(row.id());
                LOG.infof("correlationId=%s paymentId=%s eventId=%s Kafka published",
                        row.correlationId(), row.aggregateId(), row.eventId());
            } catch (Exception e) {
                String error = truncate(e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()), 500);
                try {
                    store.markFailed(row.id(), error);
                } catch (Exception dbError) {
                    LOG.errorf(dbError, "Unable to persist outbox failure for eventId=%s", row.eventId());
                }
                span.recordException(e);
                span.setStatus(StatusCode.ERROR, "Kafka publish failed");
            } finally {
                span.end();
            }
        }
    }

    private static Context parentContext(String value) {
        SpanContext remote = parseTraceparent(value);
        return remote.isValid() ? Context.root().with(Span.wrap(remote)) : Context.root();
    }

    static SpanContext parseTraceparent(String value) {
        if (value == null || value.isBlank()) return SpanContext.getInvalid();
        String[] p = value.trim().split("-");
        if (p.length != 4 || p[1].length() != 32 || p[2].length() != 16) return SpanContext.getInvalid();
        TraceFlags flags = "01".equalsIgnoreCase(p[3]) ? TraceFlags.getSampled() : TraceFlags.getDefault();
        try {
            return SpanContext.createFromRemoteParent(p[1], p[2], flags, TraceState.getDefault());
        } catch (IllegalArgumentException e) {
            return SpanContext.getInvalid();
        }
    }

    static String traceparent(SpanContext context) {
        if (context == null || !context.isValid()) return null;
        return "00-" + context.getTraceId() + "-" + context.getSpanId() + (context.isSampled() ? "-01" : "-00");
    }

    private static String truncate(String value, int max) {
        if (value == null || value.length() <= max) return value;
        return value.substring(0, max);
    }
}
