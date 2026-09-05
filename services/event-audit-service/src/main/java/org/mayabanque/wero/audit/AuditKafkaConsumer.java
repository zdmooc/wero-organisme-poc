package org.mayabanque.wero.audit;

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
import java.time.Duration;
import java.util.List;
import java.util.Properties;
import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.common.header.Header;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class AuditKafkaConsumer {
    private static final Logger LOG = Logger.getLogger(AuditKafkaConsumer.class);

    @ConfigProperty(name = "kafka.bootstrap.servers") String bootstrapServers;
    @ConfigProperty(name = "wero.events.topic", defaultValue = "payment-events") String topic;
    @ConfigProperty(name = "wero.audit.group-id", defaultValue = "payment-audit-v1") String groupId;
    @Inject AuditStore store;
    KafkaConsumer<String, String> consumer;

    @PostConstruct
    void init() {
        Properties props = new Properties();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.GROUP_ID_CONFIG, groupId);
        props.put(ConsumerConfig.CLIENT_ID_CONFIG, "mayabanque-event-audit");
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, "100");
        consumer = new KafkaConsumer<>(props);
        consumer.subscribe(List.of(topic));
    }

    @PreDestroy
    void close() {
        if (consumer != null) consumer.close();
    }

    @Scheduled(every = "1s", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    void poll() {
        try {
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(250));
            if (records.isEmpty()) return;
            for (ConsumerRecord<String, String> record : records) consume(record);
            consumer.commitSync();
        } catch (Exception e) {
            LOG.warnf("Kafka audit poll failed: %s", e.getMessage());
        }
    }

    private void consume(ConsumerRecord<String, String> record) {
        Context parent = parentContext(header(record, "traceparent"));
        Span span = GlobalOpenTelemetry.getTracer("mayabanque-audit")
                .spanBuilder("payment-events consume")
                .setSpanKind(SpanKind.CONSUMER)
                .setParent(parent)
                .startSpan();
        span.setAttribute("messaging.system", "kafka");
        span.setAttribute("messaging.destination.name", topic);
        span.setAttribute("messaging.kafka.partition", record.partition());
        span.setAttribute("messaging.kafka.offset", record.offset());
        if (record.key() != null) span.setAttribute("wero.payment_id", record.key());
        String correlationId = header(record, "X-Correlation-Id");
        if (correlationId != null) span.setAttribute("wero.correlation_id", correlationId);

        try (Scope ignored = span.makeCurrent()) {
            LOG.infof("correlationId=%s paymentId=%s partition=%d offset=%d Kafka consumed",
                    correlationId, record.key(), record.partition(), record.offset());
            store.store(record);
        } catch (RuntimeException e) {
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, "Audit persistence failed");
            throw e;
        } finally {
            span.end();
        }
    }

    private static String header(ConsumerRecord<String, String> record, String name) {
        Header h = record.headers().lastHeader(name);
        return h == null ? null : new String(h.value(), StandardCharsets.UTF_8);
    }

    private static Context parentContext(String value) {
        SpanContext remote = parseTraceparent(value);
        return remote.isValid() ? Context.root().with(Span.wrap(remote)) : Context.root();
    }

    private static SpanContext parseTraceparent(String value) {
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
}
